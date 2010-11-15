-module(rabbit_socks_socketio).

-export([unwrap_frames/1, wrap_frames/1]).

-define(FRAME, "~m~").

unwrap_frames(Bin) ->
    unwrap_frames1(Bin, []).

unwrap_frames1(<<>>, Acc) ->
    lists:reverse(Acc);
unwrap_frames1(Bin, Acc) ->
    case Bin of
        <<?FRAME, Rest/binary>> ->
            {LenStr, Rest1} =
                rabbit_socks_util:binary_splitwith(
                  fun rabbit_socks_util:is_digit/1, Rest),
            Length = list_to_integer(binary_to_list(LenStr)),
            case Rest1 of
                <<?FRAME, Data:Length/binary, Rest2/binary>> ->
                    unwrap_frames1(Rest2, [{utf8, Data} | Acc]);
                _Else ->
                    {error, malformed_frame, Bin}
            end;
        _Else ->
            {error, malformed_frame, Bin}
    end.

wrap_frames(Frame = {utf8, _}) ->
    wrap_frames1([Frame], []);
wrap_frames(Frames) ->
    wrap_frames1(Frames, []).

wrap_frames1([], IoAcc) ->
    lists:reverse(IoAcc);
wrap_frames1([{utf8, Bin} | Rest], IoAcc) ->
    case unicode:characters_to_list(Bin, utf8) of
        {error, _, _} ->
            {error, not_utf8_data, Bin};
        {incomplete, _, _} ->
            {error, incomplete_utf8_data, Bin};
        List ->
            LenStr = list_to_binary(integer_to_list(length(List))),
            wrap_frames1(Rest, [ <<?FRAME, LenStr/binary,
                                   ?FRAME, Bin/binary>> | IoAcc ])
    end.
