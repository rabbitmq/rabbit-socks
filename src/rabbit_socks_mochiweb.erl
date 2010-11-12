-module(rabbit_socks_mochiweb).

%% Start a mochiweb server and supply frames to registered interpreters.

-export([start/0]).

start() ->
    mochiweb_http:start([{name, ?MODULE}, {port, 5975}, {loop, fun loop/1}]).

loop(Req) ->
    case process_headers(Req) of
        {error, _DoesNotCompute} ->
            close_error(Req);
        {response, Protocol, Headers} ->
            send_headers(Req, Headers),
            start_socket(Protocol, Req)
    end.

%% Process the request headers and work out what the response should be
process_headers(Req) ->
    {response, rabbit_socks_echo, []}.

%% Write the headers to the response
send_headers(Req, Headers) ->
    Req:start_response({101, Headers}).

%% Close the connection with an error.
close_error(Req) ->
    Req:respond({400, [], ""}).

%% Spin up a socket to deal with frames
start_socket(Protocol, Req) ->
    {ok, Pid} = rabbit_socks_connection_sup:start_connection(Protocol),
    Sock = Req:get(sock),
    handover_socket(Sock, Pid),
    gen_fsm:send_event(Pid, {socket_ready, Sock}).

handover_socket({ssl, Sock}, Pid) ->
    ssl:controlling_process(Sock, Pid);
handover_socket(Sock, Pid) ->
    gen_tcp:controlling_process(Sock, Pid).
