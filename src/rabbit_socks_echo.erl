-module(rabbit_socks_echo).

%% Start the supervisor
-export([start_link/0]).

%% Callbacks
-export([subprotocol_name/0, init/2, open/3, handle_frame/2, terminate/1]).

subprotocol_name() -> "echo".

start_link() ->
    rabbit_socks_connection_sup:start_link(?MODULE).

init(_Path, []) ->
    {ok, undefined}.

open(WriterModule, Writer, undefined) ->
    {ok, {WriterModule, Writer}}.

terminate({_Module, _Writer}) ->
    ok.

handle_frame(Frame = {utf8, _}, Framing = {WriterModule, Writer}) ->
    WriterModule:send_frame(Frame, Writer),
    {ok, Framing}.
