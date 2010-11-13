-module(rabbit_socks_connection_sup).

-behaviour(supervisor).

% Behaviour
-export([init/1]).

% Interface
-export([start_link/1, start_connection/1]).

%% Callback for when one of these is started with supervisor:start_link/2 or/3
%% Protocol is the protocol module.
init([Protocol]) ->
    {ok, {{simple_one_for_one, 10, 10},
          [{undefined, {rabbit_socks_connection, start_link, [Protocol]},
           transient, 5, worker, [rabbit_socks_connecton]}]}}.

%% Start a supervisor for Protocol connections
start_link(Protocol) ->
    supervisor:start_link({local, Protocol}, ?MODULE, [Protocol]).

%% Start a connection using the simple_one_for_one mechanism
start_connection(Protocol) ->
    supervisor:start_child(Protocol, []).
