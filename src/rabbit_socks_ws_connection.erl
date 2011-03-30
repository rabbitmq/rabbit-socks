-module(rabbit_socks_ws_connection).

-behaviour(gen_fsm).

%% A gen_fsm for managing a WS Connection.

-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

% Interface and states
-export([start_link/2, close/2, wait_for_socket/2, wait_for_frame/2,
         close_sent/2]).

-record(state, {protocol, protocol_state, socket, parse_state}).

-define(CLOSE_TIMEOUT, 3000).

start_link(Protocol, Path) ->
    gen_fsm:start_link(?MODULE, [Protocol, Path], []).

close(Pid, Reason) ->
    gen_fsm:send_event(Pid, {close, Reason}).

% States

wait_for_socket({socket_ready, Sock},
                State = #state{ protocol = Protocol,
                                protocol_state = ProtocolState0 }) ->
    {ok, ProtocolState} = Protocol:open(rabbit_socks_ws, {self(), Sock},
                                        ProtocolState0),
    mochiweb_socket:setopts(Sock, [{active, once}]),
    State1 = State#state{parse_state = rabbit_socks_ws:initial_parse_state(),
                         protocol_state = ProtocolState,
                         socket = Sock},
    error_logger:info_msg("Connection started ~p~n", [i(State1)]),
    {next_state, wait_for_frame, State1}.

wait_for_frame({data, Data}, State = #state{
                               protocol_state = ProtocolState,
                               protocol = Protocol,
                               socket = Sock,
                               parse_state = ParseState}) ->
    case rabbit_socks_ws:parse_frame(Data, ParseState) of
        {more, ParseState1} ->
            mochiweb_socket:setopts(Sock, [{active, once}]),
            {next_state, wait_for_frame, State#state{parse_state = ParseState1}};
        {close, _ParseState1} ->
            %% TODO really necessary to reset here?
            error_logger:info_msg("Client initiated close ~p~n", [i(State)]),
            State1 = State#state{ parse_state = rabbit_socks_ws:initial_parse_state() },
            {stop, normal, close_connection(State1)};
        {frame, Frame, Rest} ->
            {ok, ProtocolState1} = Protocol:handle_frame(Frame, ProtocolState),
            wait_for_frame({data, Rest},
                           State#state{
                             protocol_state = ProtocolState1,
                             parse_state = rabbit_socks_ws:initial_parse_state()})
    end;
wait_for_frame({close, Reason}, State) ->
    error_logger:info_msg("Server initiated close ~p~n", [i(State)]),
    State1 = terminate_protocol(State),
    {next_state, close_sent, send_close(initiate_close(State1))};
wait_for_frame(_Other, State) ->
    {next_state, wait_for_frame, State}.

close_sent({data, Data}, State = #state{ parse_state = ParseState,
                                         socket = Sock }) ->
    case rabbit_socks_ws:parse_frame(Data, ParseState) of
        {more, ParseState1} ->
            mochiweb_socket:setopts(Sock, [{active, once}]),
            {next_state, close_sent, State#state{ parse_state = ParseState1 }};
        {close, _ParseState} ->
            {stop, normal, finalise_connection(State)};
        {frame, _Frame, Rest} ->
            close_sent({data, Rest},
                       State#state{
                         parse_state = rabbit_socks_ws:initial_parse_state()})
    end;
close_sent({timeout, _Ref, close_handshake}, State) ->
    {stop, normal, finalise_connection(State)}.

%% internal

%% ff are state() -> state()

initiate_close(State) ->
    _TimerRef = gen_fsm:start_timer(?CLOSE_TIMEOUT, close_handshake),
    State.

send_close(State = #state {
             socket = Socket }) ->
    mochiweb_socket:send(Socket, <<255,0>>),
    State.

close_connection(State) ->
    finalise_connection(send_close(State)).

finalise_connection(State = #state{ socket = Socket }) ->
    mochiweb_socket:close(Socket),
    State#state{ socket = closed }.

terminate_protocol(State = #state{ protocol_state = undefined }) ->
    State;
terminate_protocol(State = #state{ protocol = Protocol,
                                   protocol_state = ProtocolState }) ->
    ok = Protocol:terminate(ProtocolState),
    State#state { protocol_state = undefined }.

%% info for log messages

i(#state{ socket = closed, protocol = Protocol }) ->
    { Protocol, closed };
i(#state{ socket = Socket, protocol = Protocol }) ->
    { Protocol, socket_info(Socket) }.

socket_info(Socket) ->
    { mochiweb_socket:peername(Socket),
      mochiweb_socket:port(Socket)}.

%% gen_fsm callbacks

init([{Protocol, Args}, Path]) ->
    process_flag(trap_exit, true),
    case Protocol:init(Path, Args) of
        {ok, ProtocolState} ->
            State1 = #state{protocol = Protocol,
                            protocol_state = ProtocolState},
            {ok, wait_for_socket, State1};
        Err ->
            Err
    end.

handle_event(Event, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.
handle_sync_event(Event, _From, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.

handle_info({tcp, _Sock, Data}, State, StateData) ->
    ?MODULE:State({data, Data}, StateData);
handle_info({tcp_closed, Socket}, StateName,
            #state{socket = Socket} = StateData) ->
    error_logger:warning_msg("Connection unexpectedly dropped (in ~p)",
                             [StateName]),
    {stop, normal, terminate_protocol(StateData)};
handle_info(Info, StateName, StateData) ->
    {stop, {unexpected_info, StateName, Info}, StateData}.

%% If things happened cleanly, the protocol shoudl already be shut
%% down. However, if we crashed, we should tell it.
terminate(_Reason, _StateName, S = #state{socket = closed}) ->
    terminate_protocol(S);
terminate(_Reason, _StateName, S = #state{socket = Socket}) ->
    terminate_protocol(S),
    case catch mochiweb_socket:close(Socket) of
        _ -> ok
    end.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.
