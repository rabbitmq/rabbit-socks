-module(rabbit_socks_echo).

%% Start the supervisor
-export([start_link/0]).

%% Callbacks
-export([init/0, handle_frame/3, terminate/1]).

start_link() ->
    rabbit_socks_connection_sup:start_link(?MODULE).

init() ->
    {ok, no_state}.

terminate(no_state) ->
    ok.

handle_frame(Frame = {utf8, _}, no_state, Sock) ->
    rabbit_socks_framing:send_frame(Frame, Sock),
    {ok, no_state}.
