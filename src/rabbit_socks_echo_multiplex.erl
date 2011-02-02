-module(rabbit_socks_echo_multiplex).

%% Start the supervisor
-export([start_link/0]).

%% Callbacks
-export([init/2, handle_frame/2, terminate/1]).

start_link() ->
    rabbit_socks_connection_sup:start_link(?MODULE).

init(WriterModule, Writer) ->
    {ok, {WriterModule, Writer}}.

terminate({_Module, _Writer}) ->
    ok.

handle_frame({utf8, RawMessage}, Framing = {Writer, Arg}) ->
    {Props, Message} = decode_message(RawMessage),
    Writer:send_frame({utf8, encode_message(Props, Message)}, Arg),
    {ok, Framing}.


decode_message(RawMessage) ->
    {ok, PropsLen, L1} = extract_first_integer(RawMessage),
    JsonProps = binary_substr(RawMessage, L1+1, PropsLen),
    Rest = binary_substr(RawMessage, L1+1 + PropsLen+1),
    {ok, MsgLen, L2} = extract_first_integer(Rest),
    Msg = binary_substr(Rest, L2+1, MsgLen),
    {mochijson2:decode(JsonProps), Msg}.

encode_message(Props, Message) ->
    JsonProps = mochijson2:encode(Props),
    iolist_to_binary([integer_to_list(iolist_size(JsonProps)), " ",
		      JsonProps, " ",
		      integer_to_list(iolist_size(Message)), " ",
		      Message]).


binary_substr(Bin, Start) ->
    <<_:Start/binary, R/binary>> = Bin,
    R.
binary_substr(Bin, Start, Length) ->
    <<_:Start/binary, R:Length/binary, _/binary>> = Bin,
    R.

extract_first_integer(Bin) ->
    {ok, Regexp} = re:compile("^([0-9]*) "),
    case re:run(Bin, Regexp) of
	{match, [_, {0, L1}]} ->
	    I = list_to_integer(binary_to_list(binary_substr(Bin, 0, L1))),
	    {ok, I, L1};
	_Else ->
	    {error, bad_format}
    end.
