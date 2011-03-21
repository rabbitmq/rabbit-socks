-module(rabbit_socks_socketio).

%% Protocol
-export([init/2, open/3, handle_frame/2, terminate/1]).

%% Writer
-export([send_frame/2]).

%% Debugging/test
-export([wrap_frame/1, unwrap_frames/1]).

-define(FRAME, "~m~").
-define(GUID_PREFIX, "socks-").

-record(state, {framing, protocol_state, protocol, session}).

init(Path, [Session, Subprotocol]) ->
    case Subprotocol:init(Path, []) of
        {ok, ProtocolState} ->
            {ok, #state{session = Session,
                        protocol_state = ProtocolState,
                        protocol = Subprotocol}};
        Err ->
            Err
    end.

open(WriterModule, WriterArg,
     State = #state{ protocol = Protocol,
                     protocol_state = ProtocolState0,
                     session = Session}) ->
    {ok, ProtocolState} = Protocol:open(rabbit_socks_socketio,
                                        {WriterModule, WriterArg},
                                        ProtocolState0),
    send_frame({utf8, list_to_binary(Session)}, {WriterModule, WriterArg}),
    {ok, State#state{ protocol_state = ProtocolState }}.

handle_frame({utf8, Bin},
             State = #state{protocol = Protocol,
                            protocol_state = ProtocolState}) ->
    ProtocolState1 = lists:foldl(
                       fun (Frame, PState) ->
                               {ok, PState1} =
                                   Protocol:handle_frame(Frame, PState),
                               PState1
                       end, ProtocolState, unwrap_frames(Bin)),
    {ok, State#state{ protocol_state = ProtocolState1}}.

terminate(#state{protocol = Protocol, protocol_state = PState}) ->
    Protocol:terminate(PState).

%% We can act as a frame serialiser by writing to an underlying framing ..
send_frame(Frame, {Underlying, Writer}) ->
    Wrapped = wrap_frame(Frame),
    Underlying:send_frame({utf8, Wrapped}, Writer).

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
