-module(rabbit_socks_mochiweb).

%% Start a mochiweb server and supply frames to registered interpreters.

-export([start/1, start_mochiweb_listener/5]).

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
        Protocol ->
            start_listener(Interface, Protocol, Options),
            start_listeners(More)
    end.

start_listener(rabbit_mochiweb, Protocol, Options) ->
    start_listener({rabbit_mochiweb, '*', ?CONTEXT_PREFIX}, Protocol, Options);
start_listener({rabbit_mochiweb, Instance, Prefix}, Protocol, Options) ->
    register_with_rabbit_mochiweb(Instance, Prefix, Protocol);

start_listener(Listener, Protocol, Options) ->
    Specs = rabbit_networking:check_tcp_listener_address(
              rabbit_socks_listener_sup, Listener),
    [supervisor:start_child(rabbit_socks_listener_sup,
                            {Name,
                             {?MODULE, start_mochiweb_listener,
                              [Name, IPAddress, Port, Protocol, Options]},
                             transient, 10, worker, [rabbit_socks_mochiweb]})
     || {IPAddress, Port, _Family, Name} <- Specs].

%% TODO: when multi-mochiweb is verified, pay attention to the instance
%% argument, and keep a note of the actual path returned.
register_with_rabbit_mochiweb(Instance, Path, Protocol) ->
    Name = Protocol:name(),
    rabbit_mochiweb:register_context_handler(
      Path, makeloop(Protocol),
      io_lib:format("Rabbit Socks (~p)", [Name])).

start_mochiweb_listener(Name, IPAddress, Port, Protocol, Options) ->
    {ok, Pid} = mochiweb_http:start([{name, Name}, {ip, IPAddress},
                                     {port, Port}, {loop, makeloop(Protocol)}
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

makeloop(Protocol) ->
    fun (Req) ->
            Path = Req:get(path),
            case Path of
                "/" ++ ?CONTEXT_PREFIX ++ "/socket.io/" ++ Rest ->
                    rabbit_io(Req, Protocol, Rest);
                "/" ++ ?CONTEXT_PREFIX ++ "/websocket" ++ Rest ->
                    rabbit_ws(Req, Protocol, Rest);
                "/" ++ ?CONTEXT_PREFIX ++ "/" ++ RelPath ->
                    {file, Here} = code:is_loaded(?MODULE),
                    ModuleRoot = filename:dirname(filename:dirname(Here)),
                    Static = filename:join(filename:join(ModuleRoot, "priv"), "www"),
                    Req:serve_file(RelPath, Static)
            end
    end.

rabbit_io(Req, Protocol, Rest) ->
    %io:format("Socket.IO ~p, ~p~n", [Req, Req:recv_body()]),
    case lists:reverse(re:split(Rest, "/", [{return, list}, trim])) of
        ["websocket" | PathElemsRev] -> %% i.e., in total /socket.io/<path>/websocket
            Session = new_session_id(),
            {ok, _Pid} = websocket("http", Req, lists:reverse(PathElemsRev),
                                   {rabbit_socks_socketio, {Session, Protocol}}),
            exit(normal);
        [_Timestamp, "", PollingTransport | PathElemsRev] ->
            %io:format("New polling connection ~p ~p~n", [Protocol, PollingTransport]),
            case transport_module(PollingTransport) of
                {ok, Transport} ->
                    Session = new_session_id(),
                    {ok, _Pid} =
                        polling(Transport, Req, lists:reverse(PathElemsRev),
                                {rabbit_socks_socketio, {Session, Protocol}},
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

rabbit_ws(Req, Protocol, Rest) ->
    PathElems = re:split(Rest, "/", [{return, list}, trim]),
    {ok, _} = websocket("ws", Req, PathElems, Protocol).

websocket(Scheme, Req, PathElems, Protocol) ->
    case process_handshake(Scheme, Req, Protocol) of
        {error, DoesNotCompute} ->
            close_error(Req),
            error_logger:info_msg("Connection refused: ~p", [DoesNotCompute]);
        {response, Headers, Body} ->
            error_logger:info_msg("Connection accepted: ~p", [Req:get(peer)]),
            send_headers(Req, Headers),
            Req:send([Body]),
            start_ws_socket(Protocol, Req, PathElems)
    end.

polling(TransportModule, Req, PathElems, Protocol, Session) ->
    {ok, Pid} = rabbit_socks_connection_sup:start_connection(TransportModule,
                                                             Protocol),
    register_polling_connection(Session, TransportModule, Pid),
    gen_server:call(Pid, {open, Req}),
    gen_server:call(Pid, {recv, Req}),
    {ok, Pid}.

transport_module("xhr-polling") -> {ok, rabbit_socks_xhrpolling};
transport_module(Else) -> {error, {unsupported_transport, Else}}.

register_polling_connection(Session, Transport, Pid) ->
    true = ets:insert_new(?CONNECTION_TABLE,
                          {Session, Transport, Pid}).

process_handshake(Scheme, Req, Protocol) ->
    ProtocolName = Protocol:name(),
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
    Req:start_raw_response({"101 Web Socket Protocol Handshake", mochiweb_headers:from_list(Headers)}).

%% Close the connection with an error.
close_error(Req) ->
    Req:respond({400, [], ""}).

%% Spin up a socket to deal with frames
start_ws_socket(Protocol, Req, PathElems) ->
    {ok, Pid} = rabbit_socks_connection_sup:start_connection(rabbit_socks_ws_connection,
                                                             Protocol),
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
