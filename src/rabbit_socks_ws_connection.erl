-module(rabbit_socks_ws_connection).

-behaviour(gen_fsm).

%% A gen_fsm for managing a WS Connection.

-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

% Interface and states
-export([start_link/2, wait_for_socket/2, wait_for_frame/2]).
-record(state, {protocol, protocol_state, socket, parse_state}).

start_link(Protocol, Path) ->
    gen_fsm:start_link(?MODULE, [Protocol, Path], []).

% States

wait_for_socket({socket_ready, Sock},
                State = #state{ protocol = Protocol,
                                protocol_state = ProtocolState0 }) ->
    {ok, ProtocolState} = Protocol:open(rabbit_socks_ws, Sock, ProtocolState0),
    mochiweb_socket:setopts(Sock, [{active, once}]),
    {next_state, wait_for_frame,
     State#state{parse_state = rabbit_socks_ws:initial_parse_state(),
                 protocol_state = ProtocolState,
                 socket = Sock}};
wait_for_socket(_Other, State) ->
    {next_state, wait_for_socket, State}.

wait_for_frame({data, Data}, State = #state{
                               protocol_state = ProtocolState,
                               protocol = Protocol,
                               socket = Sock,
                               parse_state = ParseState}) ->
    case rabbit_socks_ws:parse_frame(Data, ParseState) of
        {more, ParseState1} ->
            mochiweb_socket:setopts(Sock, [{active, once}]),
            {next_state, wait_for_frame, State#state{parse_state = ParseState1}};
        {frame, Frame, Rest} ->
            {ok, ProtocolState1} = Protocol:handle_frame(Frame, ProtocolState),
            wait_for_frame({data, Rest},
                           State#state{protocol_state = ProtocolState1,
                                       parse_state = rabbit_socks_ws:initial_parse_state()})
    end;
wait_for_frame(_Other, State) ->
    {next_state, wait_for_frame, State}.

%% gen_fsm callbacks

init([{Protocol, Args}, Path]) ->
    case Protocol:init(Path, Args) of
        {ok, ProtocolState} ->
            {ok, wait_for_socket,
             #state{protocol = Protocol, protocol_state = ProtocolState}};
        Err ->
            Err
    end.

handle_event(Event, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.
handle_sync_event(Event, _From, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.

handle_info({tcp, _Sock, Data}, State, StateData) ->
    ?MODULE:State({data, Data}, StateData);
handle_info({tcp_closed, Socket}, _StateName,
            #state{socket = Socket} = StateData) ->
    {stop, normal, StateData};
handle_info(_Info, StateName, StateData) ->
    {noreply, StateName, StateData}.

terminate(normal, _StateName, #state{
            protocol = Protocol,
            protocol_state = PState,
            socket = Socket}) ->
    ok = Protocol:terminate(PState),
    mochiweb_socket:send(Socket, <<0,0,0,0,0,0,0,0,0>>),
    mochiweb_socket:close(Socket),
    ok.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.
