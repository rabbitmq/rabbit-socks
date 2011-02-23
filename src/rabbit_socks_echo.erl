-module(rabbit_socks_echo).

%% Start the supervisor
-export([start_link/0]).

%% Callbacks
-export([name/0, init/2, handle_frame/2, terminate/1]).

name() -> "echo".

start_link() ->
    rabbit_socks_connection_sup:start_link(?MODULE).

init(WriterModule, Writer) ->
    {ok, {WriterModule, Writer}}.

terminate({_Module, _Writer}) ->
    ok.

handle_frame(Frame = {utf8, _}, Framing = {Writer, Arg}) ->
    Writer:send_frame(Frame, Arg),
    {ok, Framing}.
