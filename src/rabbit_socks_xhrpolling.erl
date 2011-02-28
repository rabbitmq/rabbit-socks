-module(rabbit_socks_xhrpolling).

-behaviour(gen_server).

-export([init/1, terminate/2, code_change/3]).
-export([handle_info/2, handle_cast/2, handle_call/3]).

-export([start_link/1, send_frame/2]).

-record(state, {protocol, protocol_args, protocol_state,
               pending_frames, pending_request}).

%% Interface

start_link(Protocol) ->
    gen_server:start_link(?MODULE, [Protocol], []).

send_frame({utf8, Data}, Pid) ->
    gen_server:cast(Pid, {send, Data}),
    ok.

%% Callbacks

init([{Protocol, Args}]) ->
    %io:format("XHR polling started: ~p", [Protocol]),
    {ok, #state{protocol = Protocol,
                protocol_args = Args,
                pending_frames = [],
                pending_request = none}}.

terminate(normal, #state{protocol = Protocol, protocol_state = PState}) ->
    ok = Protocol:terminate(PState),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(_Any, State) ->
    throw("Unexpected message received").

handle_cast({send, Data}, State = #state{pending_frames = Frames,
                                         pending_request = Req}) ->
    %io:format("Sent: ~p~n", [Data]),
    case Req of
        none ->
            {noreply, State#state{pending_frames = [Data | Frames]}};
        Req ->
            Req:respond({200, [], lists:reverse([ Data | Frames])}),
            {noreply, State#state{pending_frames = [],
                                  pending_request = none}}
    end;
handle_cast(_Any, State) ->
    throw("Not implemented").

handle_call({open, Req}, _From, State = #state{protocol = Protocol,
                                               protocol_args = Args}) ->
    {ok, ProtocolState} =
        Protocol:init(rabbit_socks_xhrpolling, self(), Args),
    {reply, ok, State#state{protocol_state = ProtocolState}};
handle_call({data, Req, Data0}, _From, State = #state{protocol = Protocol,
                                                     protocol_state = PState}) ->
    {_, Data} = proplists:lookup("data", mochiweb_util:parse_qs(Data0)),
    %io:format("Incoming: ~p~n", [Data]),
    {ok, PState1} = Protocol:handle_frame({utf8, Data}, PState),
    Req:respond({200, [], "ok"}),
    {reply, ok, State#state{protocol_state = PState1}};
handle_call({recv, Req}, _From, State = #state{pending_frames = Frames}) ->
    %io:format("Recv: ~p~n", [Frames]),
    case Frames of
        [] ->
            %% TODO set timer
            {reply, ok, State#state{pending_request = Req}};
        Frames ->
            Req:respond({200, [], lists:reverse(Frames)}),
            {reply, ok, State#state{pending_frames = []}}
    end;
handle_call(_Any, State, From) ->
    throw("Not implemented").
