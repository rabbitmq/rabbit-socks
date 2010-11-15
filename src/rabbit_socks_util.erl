-module(rabbit_socks_util).

-export([is_digit/1, binary_splitwith/2]).

binary_splitwith(Pred, Bin) ->
    binary_splitwith1(Pred, Bin, 0).

binary_splitwith1(Pred, Bin, Ind) ->
    case Bin of
        <<Take:Ind/binary>> ->
            {<<>>, Take};
        <<Take:Ind/binary, Char, Rest/binary>> ->
            case Pred(Char) of
                true  -> binary_splitwith1(Pred, Bin, Ind + 1); 
                false -> {Take, <<Char, Rest/binary>>}
            end
    end.

is_digit($0) -> true;
is_digit($1) -> true;
is_digit($2) -> true;
is_digit($3) -> true;
is_digit($4) -> true;
is_digit($5) -> true;
is_digit($6) -> true;
is_digit($7) -> true;
is_digit($8) -> true;
is_digit($9) -> true;
is_digit(_) -> false.
