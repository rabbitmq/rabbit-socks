-module(rabbit_socks_connection_sup).

-behaviour(supervisor).

% Behaviour
-export([init/1]).

% Interface
-export([start_link/1, start_connection/2]).

%% We have a supervisor for each front-end, i.e., each implementation
%% of connection.  This way we can parameterise on the connection
%% module and use simple_one_for_one when starting connections.

%% Callback for when one of these is started with supervisor:start_link/2 or/3
%% Protocol is the protocol module.
init([ConnectionType]) ->
    {ok, {{simple_one_for_one, 10, 10},
          [{undefined, {ConnectionType, start_link, []},
           transient, 5, worker, [ConnectionType]}]}}.

%% Start a supervisor for connections using module ConnectionType
start_link(ConnectionType) ->
    supervisor:start_link({local, ConnectionType}, ?MODULE, [ConnectionType]).

%% Start a connection using the simple_one_for_one mechanism
start_connection(ConnectionType, Protocol) ->
    error_logger:info_msg("Starting connection ~p with ~p~n", [ConnectionType, Protocol]),
    supervisor:start_child(ConnectionType, [Protocol]).
