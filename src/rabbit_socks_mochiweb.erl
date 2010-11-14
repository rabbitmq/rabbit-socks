-module(rabbit_socks_mochiweb).

%% Start a mochiweb server and supply frames to registered interpreters.

-export([start/0]).

start() ->
    mochiweb_http:start([{name, ?MODULE}, {port, 5975}, {loop, fun loop/1}]).

loop(Req) ->
    case process_handshake(Req) of
        {error, _DoesNotCompute} ->
            close_error(Req);
        {response, Protocol, Headers, Body} ->
            send_headers(Req, Headers),
            Req:send([Body]),
            start_socket(Protocol, Req)
    end.

%% Process the request headers and work out what the response should be
process_handshake(Req) ->
    Origin = Req:get_header_value("origin"),
    Protocol = Req:get_header_value("websocket-protocol"),
    Host = Req:get_header_value("Host"),
    Location = "ws://localhost:5975/",
    FirstBit = [{"Upgrade", "WebSocket"},
                {"Connection", "Upgrade"}],
    case Req:get_header_value("Sec-WebSocket-Key1") of
        undefined ->
            {response, rabbit_socks_echo, 
             FirstBit ++
                 [{"WebSocket-Origin", Origin},
                  {"WebSocket-Location", Location}],
            <<>>};
        Key1 ->
            Key2 = Req:get_header_value("Sec-WebSocket-Key2"),
            Key3 = Req:recv(8),
            Hash = handshake_hash(Key1, Key2, Key3),
            {response, rabbit_socks_echo,
             FirstBit ++
                 [{"Sec-WebSocket-Origin", Origin},
                  {"Sec-WebSocket-Location", Location}],
             Hash}
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
start_socket(Protocol, Req) ->
    {ok, Pid} = rabbit_socks_connection_sup:start_connection(Protocol),
    Sock = Req:get(socket),
    handover_socket(Sock, Pid),
    gen_fsm:send_event(Pid, {socket_ready, Sock}),
    exit(normal).

handover_socket({ssl, Sock}, Pid) ->
    ssl:controlling_process(Sock, Pid);
handover_socket(Sock, Pid) ->
    gen_tcp:controlling_process(Sock, Pid).
