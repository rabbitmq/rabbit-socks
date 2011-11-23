-module(rabbit_socks_xhrpolling).

-behaviour(gen_server).

-export([init/1, terminate/2, code_change/3]).
-export([handle_info/2, handle_cast/2, handle_call/3]).

-export([start_link/2, send_frame/2, close_transport/1]).

-record(state, {protocol, protocol_args, protocol_state,
               pending_frames, pending_request}).

%% Interface

start_link(ProtocolMA, Path) ->
    gen_server:start_link(?MODULE, [ProtocolMA, Path], []).

send_frame({utf8, Data}, Pid) ->
    gen_server:cast(Pid, {send, Data}),
    ok.

close_transport(Pid) ->
    gen_server:cast(Pid, close_transport),
    ok.

%% Callbacks

init([{Protocol, Args}, Path]) ->
    %io:format("XHR polling started: ~p", [Protocol]),
    case Protocol:init(Path, Args) of
        {ok, ProtocolState} ->
            {ok, #state{protocol = Protocol,
                        protocol_state = ProtocolState,
                        pending_frames = [],
                        pending_request = none}};
        Err ->
            Err
    end.

terminate(normal, #state{protocol = Protocol, protocol_state = PState}) ->
    ok = Protocol:terminate(PState),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(Any, State) ->
    {stop, {unexpect_info, Any}, State}.

handle_cast({send, Data}, State = #state{pending_frames = Frames,
                                         pending_request = Pending}) ->
    %io:format("Sent: ~p~n", [Data]),
    case Pending of
        none ->
            {noreply, State#state{pending_frames = [Data | Frames]}};
        {Req, From} ->
            Req:respond({200, get_headers(), lists:reverse([ Data | Frames])}),
            gen_server:reply(From, ok),
            {noreply, State#state{pending_frames = [],
                                  pending_request = none}}
    end;

handle_cast(close_transport, State = #state{pending_request = Pending}) ->
    case Pending of
        none -> ok;
        {OldReq, OldFrom} ->
            %% If the socket is Req: is closed, this command will
            %% trigger exit(normal). We hate mochwieb. Sorry.
            % OldReq:respond({200, get_headers(), []}),
            gen_server:reply(OldFrom, ok)
    end,
    {stop, normal, State#state{pending_request = none}};

handle_cast(Any, State) ->
    {stop, {unexpected_cast, Any}, State}.

handle_call({open, _Req}, _From,
            State = #state{ protocol = Protocol,
                            protocol_state = ProtocolState0 }) ->
    {ok, ProtocolState} = Protocol:open(
                            rabbit_socks_xhrpolling, self(), ProtocolState0),
    {reply, ok, State#state{ protocol_state = ProtocolState }};
handle_call({data, Req, Data0}, _From, State = #state{protocol = Protocol,
                                                      protocol_state = PState}) ->
    {_, Data} = proplists:lookup("data", mochiweb_util:parse_qs(Data0)),
    %io:format("Incoming: ~p~n", [Data]),
    {ok, PState1} = Protocol:handle_frame({utf8, Data}, PState),
    Req:respond({200, get_headers(), "ok"}),
    {reply, ok, State#state{protocol_state = PState1}};
handle_call({recv, Req}, From, State = #state{pending_frames = Frames,
                                              pending_request = Pending}) ->
    %io:format("Recv: ~p~n", [Frames]),
    case Pending of
        none -> ok;
        {OldReq, OldFrom} ->
            %% Although unlikely, it's possible to have more than one
            %% hanging request. We don't support that. Instead let's
            %% just finish the previous one with an empty response.
            OldReq:respond({200, get_headers(), []}),
            gen_server:reply(OldFrom, ok)
    end,
    case Frames of
        [] ->
            %% TODO: is it possible to catch socket-close event?
            {noreply, State#state{pending_request = {Req, From}}};
        Frames ->
            Req:respond({200, get_headers(), lists:reverse(Frames)}),
            {reply, ok, State#state{pending_frames = [],
                                    pending_request = none}}
    end;
handle_call(Any, From, State) ->
    {stop, {unexpected_call, Any, From}, State}.


get_headers() ->
    [{"Access-Control-Allow-Origin", "*"}].
