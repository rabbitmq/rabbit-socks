-module(rabbit_socks_mochiweb).

%% Start a mochiweb server and supply frames to registered interpreters.

-export([start/1, start_listener/4]).

-define(CONNECTION_TABLE, socks_connections).
-define(SESSION_PREFIX, "socks").

start(Listeners) ->
    %% FIXME each listener should have its own table
    ets:new(?CONNECTION_TABLE, [public, named_table]),
    start_listeners(Listeners).

start_listeners([]) ->
    ok;
start_listeners([{Listener, Options} | More]) ->
    Specs = rabbit_networking:check_tcp_listener_address(
              rabbit_socks_listener_sup, Listener),

    [supervisor:start_child(rabbit_socks_listener_sup,
                            {Name,
                             {?MODULE, start_listener,
                              [Name, IPAddress, Port, Options]},
                             transient, 10, worker, [rabbit_socks_mochiweb]})
     || {IPAddress, Port, _Family, Name} <- Specs],
    %% Family is ignored, mochiweb claims to figure out IPv6 from the address
    %% although it tests inet:getaddr("localhost", inet6) which does not
    %% work on my machine...
    start_listeners(More).

start_listener(Name, IPAddress, Port, Options) ->
    {ok, Pid} = mochiweb_http:start([{name, Name}, {ip, IPAddress},
                                     {port, Port}, {loop, fun loop/1} | Options]),
    rabbit_networking:tcp_listener_started(
      case proplists:get_bool(ssl, Options) of
          true  -> 'websocket/socket.io (SSL)';
          false -> 'websocket/socket.io'
      end, IPAddress, Port),
    {ok, Pid}.

%% URL scheme:
%% For websockets, we accept either of /websocket/<protocol> or using
%% a header to determine the protocol.
%%
%% For socket.io, the client library will append
%% /<transport>/<sessionid> to whatever prefix it is configured to
%% use.  We want to be able to put the protocol somewhere, so we use a
%% pattern /socket.io/<protocol>/<transport>/<sessionid>.  The client
%% should always set the prefix to include the protocol, even if the
%% transport is websockets.

loop(Req) ->
    case Req:get(path) of
        Path = "/socket.io/" ++ Rest ->
            rabbit_io(Req, Path, Rest);
        Path = "/websocket/" ++ Rest ->
            rabbit_ws(Req, Path, Rest);
        "/" ++ Path ->
            {file, Here} = code:is_loaded(?MODULE),
            ModuleRoot = filename:dirname(filename:dirname(Here)),
            Static = filename:join(filename:join(ModuleRoot, "priv"), "www"),
            Req:serve_file(Path, Static)
    end.

rabbit_io(Req, Path, Rest) ->
    %io:format("Socket.IO ~p, ~p~n", [Req, Req:recv_body()]),
    case re:split(Rest, "/", [{return, list}, trim]) of
        [Protocol, "websocket"] ->
            case supported_protocol(Protocol) of
                {ok, Name, Module} ->
                    Session = new_session_id(),
                    {ok, _Pid} = websocket(Req, Path, Name,
                                           {rabbit_socks_socketio, {Session, Module}}),
                    exit(normal);
                {error, Err} ->
                    throw(Err)
            end;
        [Protocol, PollingTransport, "", _Timestamp] ->
            %io:format("New polling connection ~p ~p~n", [Protocol, PollingTransport]),
            case supported_protocol(Protocol) of
                {ok, Name, Module} ->
                    case transport_module(PollingTransport) of
                        {ok, Transport} ->
                            Session = new_session_id(),
                            {ok, _Pid} =
                                polling(Transport, Req,
                                        {rabbit_socks_socketio, {Session, Module}},
                                        Session);
                        {error, Err} ->
                            Req:respond({404, [], "Bad transport"})
                    end;
                {error, Err} ->
                    Req:respond({404, [], "Bad protocol"})
            end;
        [Protocol, Transport, Session, Operation] ->
            %io:format("Existing connection ~p~n", [Session]),
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

rabbit_ws(Req, Path, Rest) ->
    case ws_protocol(Req, Rest) of
        {ok, ProtocolName, ProtocolModule} ->
            {ok, _} = websocket(Req, Path, ProtocolName, ProtocolModule),
            exit(normal);
        {error, Err} ->
            throw(Err)
    end.

websocket(Req, Path, ProtocolName, Protocol) ->
    case process_handshake(Req, Path, ProtocolName) of
        {error, DoesNotCompute} ->
            close_error(Req),
            error_logger:info_msg("Connection refused: ~p", [DoesNotCompute]);
        {response, Headers, Body} ->
            error_logger:info_msg("Connection accepted: ~p", [Req:get(peer)]),
            send_headers(Req, Headers),
            Req:send([Body]),
            start_ws_socket(Protocol, Req)
    end.

polling(TransportModule, Req, Protocol, Session) ->
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

process_handshake(Req, Path, Protocol) ->
    Origin = Req:get_header_value("origin"),
    Host = Req:get_header_value("Host"),
    %% FIXME un-hardcode -- clients expect something specific here
    Location = "ws://localhost:5975" ++ Path,
    FirstBit = [{"Upgrade", "WebSocket"},
                {"Connection", "Upgrade"}],
    case Req:get_header_value("Sec-WebSocket-Key1") of
        undefined ->
            {response,
             FirstBit ++
                 [{"WebSocket-Origin", Origin},
                  {"WebSocket-Location", Location},
                  {"WebSocket-Protocol", Protocol}],
             <<>>};
        Key1 ->
            Key2 = Req:get_header_value("Sec-WebSocket-Key2"),
            Key3 = Req:recv(8),
            Hash = handshake_hash(Key1, Key2, Key3),
            {response,
             FirstBit ++
                 [{"Sec-WebSocket-Origin", Origin},
                  {"Sec-WebSocket-Location", Location},
                  {"Sec-WebSocket-Protocol", Protocol}],
             Hash}
    end.

%% FIXME baulk if the protocol is given but path isn't empty
ws_protocol(Req, Path) ->
    Protocol = case Req:get_header_value("WebSocket-Protocol") of
                   undefined ->
                       case Req:get_header_value("Sec-WebSocket-Protocol") of
                           undefined ->
                               Path;
                           Prot ->
                               Prot
                       end;
                   Prot ->
                       Prot
               end,
    supported_protocol(Protocol).

supported_protocol(Prot) ->
    case string:to_lower(Prot) of
        "echo"  -> {ok, Prot, rabbit_socks_echo};
        "stomp" -> {ok, Prot, rabbit_socks_stomp};
        Else    -> {error, {unknown_protocol, Else}}
    end.

handshake_hash(Key1, Key2, Key3) ->
    erlang:md5([reduce_key(Key1), reduce_key(Key2), Key3]).

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
start_ws_socket(Protocol, Req) ->
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
