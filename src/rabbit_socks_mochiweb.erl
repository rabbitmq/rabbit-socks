-module(rabbit_socks_mochiweb).

%% Start a mochiweb server and supply frames to registered interpreters.

-export([start/1, start_listener/3]).
%% For rabbit_socks_listener_sup callback
-export([start_mochiweb_listener/5]).

-define(CONNECTION_TABLE, socks_connections).
-define(SESSION_PREFIX, "socks").
-define(CONTEXT_PREFIX, "socks").

start(Listeners) ->
    %% FIXME each listener should have its own table
    ets:new(?CONNECTION_TABLE, [public, named_table]),
    start_listeners(Listeners).

start_listeners([]) ->
    ok;
start_listeners([{Interface, Options} | More]) ->
    case proplists:get_value(protocol, Options, undefined) of
        undefined ->
            exit({no_protocol, Options});
        Subprotocol ->
            start_listener(Interface, Subprotocol, Options),
            start_listeners(More)
    end.

start_listener(rabbit_mochiweb, Subprotocol, Options) ->
    start_listener({rabbit_mochiweb, '*',
                    ?CONTEXT_PREFIX}, Subprotocol, Options);
start_listener({rabbit_mochiweb, Instance, Prefix}, Subprotocol, Options) ->
    register_with_rabbit_mochiweb(Instance, Prefix, Subprotocol);

start_listener(Listener, Subprotocol, Options) ->
    Specs = rabbit_networking:check_tcp_listener_address(
              rabbit_socks_listener_sup, Listener),
    [supervisor:start_child(rabbit_socks_listener_sup,
                            {Name,
                             {?MODULE, start_mochiweb_listener,
                              [Name, IPAddress, Port, Subprotocol, Options]},
                             transient, 10, worker, [rabbit_socks_mochiweb]})
     || {IPAddress, Port, _Family, Name} <- Specs].

%% TODO: when multi-mochiweb is verified, pay attention to the instance
%% argument, and keep a note of the actual path returned.
register_with_rabbit_mochiweb(Instance, Path, Subprotocol) ->
    Name = Subprotocol:subprotocol_name(),
    rabbit_mochiweb:register_context_handler(
      Path, makeloop(Subprotocol),
      io_lib:format("Rabbit Socks (~p)", [Name])).

start_mochiweb_listener(Name, IPAddress, Port, Subprotocol, Options) ->
    {ok, Pid} = mochiweb_http:start([{name, Name}, {ip, IPAddress},
                                     {port, Port}, {loop, makeloop(Subprotocol)}
                                     | Options]),
    rabbit_networking:tcp_listener_started(
      case proplists:get_bool(ssl, Options) of
          true  -> 'websocket/socket.io (SSL)';
          false -> 'websocket/socket.io'
      end, IPAddress, Port),
    {ok, Pid}.

%% URL scheme:
%%
%% Since our protocol is per-listener, we already know it at this
%% point; all we can do is check that the client has the same idea of
%% what it is.
%%
%% For websockets, we accept /websocket/<path>, and the path is given to the
%% protocol.
%%
%% For socket.io, the client library will append
%% /<transport>/<sessionid> to whatever prefix it is configured to
%% use.  Therefore our pattern, for connection initiation, is
%% /socket.io/<path>/<transport>/<sessionid>.

makeloop(Subprotocol) ->
    fun (Req) ->
            Path = Req:get(path),
            case Path of
                "/" ++ ?CONTEXT_PREFIX ++ "/socket.io/" ++ Rest ->
                    rabbit_io(Req, Subprotocol, Rest);
                "/" ++ ?CONTEXT_PREFIX ++ "/websocket" ++ Rest ->
                    rabbit_ws(Req, Subprotocol, Rest);
                "/" ++ ?CONTEXT_PREFIX ++ "/" ++ RelPath ->
                    {file, Here} = code:is_loaded(?MODULE),
                    ModuleRoot = filename:dirname(filename:dirname(Here)),
                    Static = filename:join(filename:join(ModuleRoot, "priv"), "www"),
                    Req:serve_file(RelPath, Static)
            end
    end.

rabbit_io(Req, Subprotocol, Rest) ->
    %io:format("Socket.IO ~p, ~p~n", [Req, Req:recv_body()]),
    case lists:reverse(re:split(Rest, "/", [{return, list}, trim])) of
        ["websocket" | PathElemsRev] -> %% i.e., in total /socket.io/<path>/websocket
            Session = new_session_id(),
            {ok, _Pid} = websocket(Req:get(scheme), Req,
                                   lists:reverse(PathElemsRev),
                                   Subprotocol,
                                   %% Wrap the subprotocol in Socket.IO framing
                                   {rabbit_socks_socketio, [Session, Subprotocol]}),
            exit(normal);
        [_Timestamp, "", PollingTransport | PathElemsRev] ->
            %io:format("New polling connection ~p ~p~n", [Protocol, PollingTransport]),
            case transport_module(PollingTransport) of
                {ok, Transport} ->
                    Session = new_session_id(),
                    {ok, _Pid} =
                        polling(Transport, Req, lists:reverse(PathElemsRev),
                                {rabbit_socks_socketio, [Session, Subprotocol]},
                                Session);
                {error, Err} ->
                    Req:respond({404, [], "Bad transport"})
            end;
        [Operation, Session, Transport | _PathElemsRev] ->
            %% io:format("Existing connection ~p~n", [Session]),
            case transport_module(Transport) of
                {ok, TransportModule} ->
                    case ets:lookup(?CONNECTION_TABLE, Session) of
                        [{Session, TransportModule, Pid}] ->
                            case Operation of
                                "send" ->
                                    %% NB: recv_body caches the body in the process
                                    %% dictionary.  This must be done in the mochiweb
                                    %% process to have any chance of working.
                                    gen_server:call(Pid, {data, Req, Req:recv_body()});
                                Timestamp ->
                                    gen_server:call(Pid, {recv, Req})
                            end;
                        [] ->
                            Req:not_found()
                    end;
                {error, Err} ->
                    Req:respond({404, [], "Bad transport"})
            end;
        Else ->
            Req:not_found()
    end.

rabbit_ws(Req, Subprotocol, Rest0) ->
    Rest = case Rest0 of
               "/" ++ R -> R;
               R        -> R
           end,
    PathElems = re:split(Rest, "/", [{return, list}, trim]),
    Scheme = case Req:get(socket) of
                 {ssl, _Sock} -> "wss";
                 _Sock        -> "ws"
             end,
    {ok, _} = websocket(Scheme, Req, PathElems, Subprotocol, {Subprotocol, []}),
    exit(normal).

websocket(Scheme, Req, PathElems, Subprotocol, SubprotocolMA) ->
    case process_handshake(Scheme, Req, Subprotocol) of
        {error, DoesNotCompute} ->
            close_error(Req),
            error_logger:info_msg("Connection refused: ~p", [DoesNotCompute]);
        {response, Headers, Body} ->
            error_logger:info_msg("Connection accepted: ~p", [Req:get(peer)]),
            send_headers(Req, Headers),
            Req:send([Body]),
            start_ws_socket(SubprotocolMA, Req, PathElems)
    end.

polling(TransportModule, Req, PathElems, SubprotocolMA, Session) ->
    {ok, Pid} = rabbit_socks_connection_sup:start_connection(TransportModule,
                                                             SubprotocolMA, PathElems),
    register_polling_connection(Session, TransportModule, Pid),
    gen_server:call(Pid, {open, Req}),
    gen_server:call(Pid, {recv, Req}),
    {ok, Pid}.

transport_module("xhr-polling") -> {ok, rabbit_socks_xhrpolling};
transport_module(Else) -> {error, {unsupported_transport, Else}}.

register_polling_connection(Session, Transport, Pid) ->
    true = ets:insert_new(?CONNECTION_TABLE,
                          {Session, Transport, Pid}).

process_handshake(Scheme, Req, Subprotocol) ->
    ProtocolName = Subprotocol:subprotocol_name(),
    Origin = Req:get_header_value("Origin"),
    Location = make_location(Scheme, Req),
    FirstBit = [{"Upgrade", "WebSocket"},
                {"Connection", "Upgrade"}],
    case Req:get_header_value("Sec-WebSocket-Key1") of
        undefined ->
            {response,
             FirstBit ++
             [{"WebSocket-Origin", Origin},
              {"WebSocket-Location", Location},
              {"WebSocket-Protocol", ProtocolName}],
             <<>>};
        Key1 ->
            Key2 = Req:get_header_value("Sec-WebSocket-Key2"),
            Key3 = Req:recv(8),
            Hash = handshake_hash(Key1, Key2, Key3),
            {response,
             FirstBit ++
             [{"Sec-WebSocket-Origin", Origin},
              {"Sec-WebSocket-Location", Location},
              {"Sec-WebSocket-Protocol", ProtocolName}],
             Hash}
    end.

handshake_hash(Key1, Key2, Key3) ->
    erlang:md5([reduce_key(Key1), reduce_key(Key2), Key3]).

make_location(Scheme, Req) ->
    Host = Req:get_header_value("Host"),
    Resource = Req:get(raw_path),
    mochiweb_util:urlunsplit(
      {Scheme, Host, Resource, "", ""}).

reduce_key(Key) when is_list(Key) ->
    {NumbersRev, NumSpaces} = lists:foldl(
                             fun (32, {Nums, NumSpaces}) ->
                                     {Nums, NumSpaces + 1};
                                 (Digit, {Nums, NumSpaces})
                                   when Digit > 47 andalso Digit < 58 ->
                                     {[Digit | Nums], NumSpaces};
                                 (_Other, Res) ->
                                     Res
                             end, {[], 0}, Key),
    OriginalNum = list_to_integer(lists:reverse(NumbersRev)) div NumSpaces,
    <<OriginalNum:32/big-unsigned-integer>>.

%% Write the headers to the response
send_headers(Req, Headers) ->
    Req:start_raw_response({"101 Web Socket Protocol Handshake",
                            mochiweb_headers:from_list(Headers)}).

%% Close the connection with an error.
close_error(Req) ->
    Req:respond({400, [], ""}).

%% Spin up a socket to deal with frames
start_ws_socket(SubprotocolMA, Req, PathElems) ->
    {ok, Pid} = rabbit_socks_connection_sup:start_connection(
                  rabbit_socks_ws_connection, SubprotocolMA, PathElems),
    Sock = Req:get(socket),
    handover_socket(Sock, Pid),
    gen_fsm:send_event(Pid, {socket_ready, Sock}),
    {ok, Pid}.

handover_socket({ssl, Sock}, Pid) ->
    ssl:controlling_process(Sock, Pid);
handover_socket(Sock, Pid) ->
    gen_tcp:controlling_process(Sock, Pid).

new_session_id() ->
    [ C || C <- rabbit_guid:string_guid(?SESSION_PREFIX),
           C /= $+, C /= $=, C /= $/ ].
