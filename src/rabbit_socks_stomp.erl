-module(rabbit_socks_stomp).

-export([start_link/0]).

%% callbacks
-export([subprotocol_name/0, init/2, open/3, handle_frame/2, terminate/1]).

%% Start supervisor
start_link() ->
    rabbit_socks_connection_sup:start_link(?MODULE).

subprotocol_name() -> "STOMP".

%% Spin up STOMP frame processor
init(_Path, []) ->
    {ok, undefined}.

open(Writer, WriterArg, undefined) ->
    gen_server:start_link(rabbit_stomp_processor,
                          [{Writer, WriterArg}], []).

terminate(Pid) ->
    %% FIXME
    exit(Pid, normal).

handle_frame({utf8, Bin}, Pid) ->
    %% Expect a whole frame at a time, but not the terminator
    StompBin = unicode:characters_to_list(Bin),
    {ok, StompFrame, []} = rabbit_stomp_frame:parse(
                             StompBin, rabbit_stomp_frame:initial_state()),
    rabbit_stomp_processor:process_frame(Pid, StompFrame),
    {ok, Pid}.
