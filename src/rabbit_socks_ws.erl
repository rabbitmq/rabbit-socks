-module(rabbit_socks_ws).

%% Parser
-export([initial_parse_state/0, parse_frame/2]).

%% Writer
-export([send_frame/2]).

-record(parse, {type = unknown, fragments_rev = [], remaining = unknown}).

-define(TEXT_FRAME_START, 0).
-define(TEXT_FRAME_END, 255).

initial_parse_state() ->
    #parse{}.

parse_frame(<<>>, Parse) ->
    {more, Parse};
parse_frame(<<?TEXT_FRAME_START, Rest/binary>>,
            Parse = #parse{type = unknown,
                           fragments_rev = [],
                           remaining = unknown}) ->
    parse_frame(Rest, Parse#parse{type = utf8});
parse_frame(Bin, Parse = #parse{type = utf8}) ->
    parse_utf8_frame(Bin, Parse, 0);
%% TODO binary frames
parse_frame(Bin, Parse) ->
    {error, unrecognised_frame, {Bin, Parse}}.

parse_utf8_frame(Bin, Parse = #parse{type = utf8,
                                     fragments_rev = Frags},
                 Index) ->
    case Bin of
        <<Head:Index/binary, ?TEXT_FRAME_END, Rest/binary>> ->
            {frame, {utf8, lists:reverse([Head | Frags])}, Rest};
        <<Whole:Index/binary>> ->
            {more, Parse#parse{ fragments_rev = [ Whole | Frags] }};
        Bin ->
            parse_utf8_frame(Bin, Parse, Index + 1)
    end.

send_frame({utf8, Data}, Sock) ->
    send_frame(Data, Sock);
send_frame(IoList, Sock) ->
    mochiweb_socket:send(Sock, [<<?TEXT_FRAME_START>>, IoList, <<?TEXT_FRAME_END>>]).
