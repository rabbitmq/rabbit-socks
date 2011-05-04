-module(rabbit_socks_socketio).

%% Protocol
-export([init/2, open/3, handle_frame/2, terminate/1]).

%% Writer
-export([send_frame/2, close_transport/1]).

%% ---------------------------

-export([start_link/1]).

-behaviour(gen_server).
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

%% ---------------------------

-export([send_heartbeat/1]).

-define(FRAME, "~m~").
-define(HEARTBEAT_DELAY, 15000).

%% ---------------------------

init(Path, [Session, RightProtocol]) ->
    process_flag(trap_exit, true),
    case RightProtocol:init(Path, []) of
        {ok, RightProtocolState} ->
            {ok, Pid} = rabbit_socks_socketio_sup:start_child(
                          [Session, RightProtocol, RightProtocolState]),
            {ok, Pid};                          % LeftState
        Err ->
            Err
    end.

open(WriterModule, WriterArg, LeftState) ->
    gen_server:call(LeftState, {open, {WriterModule, WriterArg}}, infinity),
    {ok, LeftState}.

handle_frame(Frame, LeftState) ->
    gen_server:cast(LeftState, {handle_frame, Frame}),
    {ok, LeftState}.

terminate(LeftState) ->
    gen_server:call(LeftState, terminate, infinity),
    ok.

send_frame(Frame, RightState) ->
    gen_server:cast(RightState, {send, Frame}),
    {ok, RightState}.

close_transport(RightState) ->
    gen_server:cast(RightState, close_transport),
    {ok, RightState}.

%% ---------------------------

send_heartbeat(Pid) ->
    gen_server:cast(Pid, send_heartbeat).

%% ---------------------------

start_link(Params) ->
    gen_server:start_link(?MODULE, Params, []).

%% ---------------------------

-record(state, {session, right_protocol, right_protocol_state, left_callback,
                heartbeat_tref, heartbeat_expected}).

init([Session, RightProtocol, RightProtocolState]) ->
    State0 = #state{session = Session,
                   right_protocol = RightProtocol,
                   right_protocol_state = RightProtocolState},
    {ok, delay_heartbeat(State0)}.

terminate(Reason, #state{heartbeat_tref = TRef}) ->
    case TRef of
        undefined ->
            ok;
        _ ->
            timer:cancel(TRef)
    end,
    io:format("~p died with ~p ~n", [?MODULE, Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(Any, State) ->
    {stop, {unexpected_message, Any}, State}.

handle_cast({handle_frame, {utf8, Bin}},
            State = #state{right_protocol = RightProtocol,
                           right_protocol_state = RightProtocolState0,
                           heartbeat_expected = HeartbeatExpectedFrame}) ->
    Fun = fun (Frame, {Heartbeat, PState}) ->
                  case Frame of
                      Heartbeat ->
                          {undefined, PState};
                      _ ->
                          {ok, PState1} =
                              RightProtocol:handle_frame(Frame, PState),
                          {Heartbeat, PState1}
                  end
          end,
    {Heartbeat1, RightProtocolState1} =
        lists:foldl(Fun, {HeartbeatExpectedFrame, RightProtocolState0},
                    unwrap_frames(Bin)),
    case Heartbeat1 of
        HeartbeatExpectedFrame ->
            ok;
        undefined ->
            io:format("got heartbeat ~p~n", [HeartbeatExpectedFrame])
    end,
    State1 = State#state{right_protocol_state = RightProtocolState1,
                         heartbeat_expected = Heartbeat1},
    {noreply, delay_heartbeat(State1)};

handle_cast({send, Frame}, State) ->
    do_send_frame(Frame, State),
    {noreply, State};

handle_cast(send_heartbeat, State = #state{heartbeat_expected = undefined}) ->
    Frame = construct_heartbeat_frame(),
    io:format("send heartbeat ~p~n", [Frame]),
    do_send_frame(Frame, State),
    {noreply, State#state{heartbeat_expected = Frame}};

handle_cast(send_heartbeat, State = #state{heartbeat_expected = NotReceived}) ->
    io:format("socketio:heartbeat not received ~p. closing. ~n", [NotReceived]),
    handle_cast(close_transport, State);

handle_cast(close_transport,
            State = #state{left_callback = {WriterModule, WriterArg}}) ->
    WriterModule:close_transport(WriterArg),
    {noreply, State};

handle_cast(Any, State) ->
    {stop, {unexpected_message, Any}, State}.


handle_call({open, LeftCallback}, _From,
            State = #state{session = Session,
                           right_protocol = RightProtocol,
                           right_protocol_state = RightProtocolState0}) ->
    {ok, RightProtocolState1} = RightProtocol:open(?MODULE, self(), % RightState
                                                   RightProtocolState0),
    State1 = State#state{right_protocol_state = RightProtocolState1,
                         left_callback = LeftCallback},
    do_send_frame({utf8, list_to_binary(Session)}, State1),
    {reply, ok, State1};

handle_call(terminate, _From,
            State = #state{right_protocol = RightProtocol,
                           right_protocol_state = RightProtocolState}) ->
    RightProtocol:terminate(RightProtocolState),
    {stop, normal, ok, State};

handle_call(Any, _From, State) ->
    {stop, {unexpected_message, Any}, State}.

%% ---------------------------

do_send_frame(Frame, #state{left_callback = {WriterModule, WriterArg}}) ->
    Wrapped = wrap_frame(Frame),
    WriterModule:send_frame({utf8, Wrapped}, WriterArg).


delay_heartbeat(State = #state{heartbeat_tref = TRef0}) ->
    case TRef0 of
        undefined ->
            ok;
        _ ->
            timer:cancel(TRef0)
    end,
    {ok, TRef} = timer:apply_after(?HEARTBEAT_DELAY,
                                   ?MODULE, send_heartbeat, [self()]),
    State#state{heartbeat_tref = TRef}.

construct_heartbeat_frame() ->
    %% Keep it small.
    R = random:uniform(9999),
    {utf8, list_to_binary("~h~" ++ integer_to_list(R))}.


unwrap_frames(List) when is_list(List) ->
    unwrap_frames(iolist_to_binary(List));
unwrap_frames(Bin) ->
    unwrap_frames_unicode(unicode:characters_to_list(Bin, utf8), []).

unwrap_frames_unicode([], Acc) ->
    lists:reverse(Acc);
unwrap_frames_unicode(Frame, Acc) ->
    case Frame of
        ?FRAME ++ Rest ->
            {LenStr, Rest1} = lists:splitwith(fun rabbit_socks_util:is_digit/1,
                                              Rest),
            Length = list_to_integer(LenStr),
            case Rest1 of
                ?FRAME ++ Rest2 ->
                    {Data, Rest3} = lists:split(Length, Rest2),
                    BinData = unicode:characters_to_binary(Data, utf8),
                    unwrap_frames_unicode(Rest3, [{utf8, BinData} | Acc]);
                _Else ->
                    {error, malformed_frame, Frame}
            end;
        _Else ->
            {error, malformed_frame, Frame}
    end.

wrap_frame({utf8, Bin}) ->
    case unicode:characters_to_list(Bin, utf8) of
        {error, _, _} ->
            {error, not_utf8_data, Bin};
        {incomplete, _, _} ->
            {error, incomplete_utf8_data, Bin};
        List ->
            LenStr = list_to_binary(integer_to_list(length(List))),
            [?FRAME, LenStr, ?FRAME, List]
    end;
wrap_frame(IoList) ->
    wrap_frame({utf8, iolist_to_binary(IoList)}).
