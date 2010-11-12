-module(rabbit_socks_connection_sup).

-behaviour(supervisor).

% Behaviour
-export([init/1]).

% Interface
-export([start_link/2, start_connection/1]).

init([Module, Args]) ->
    {ok, {{simple_one_for_one, 10, 10},
          [{undefined, {Module, start_link, Args},
           transient, 5, worker, [Module]}]}}.

start_link(Module, Args) ->
    supervisor:start_link({local, Module}, ?MODULE, [Module, Args]).

start_connection(SupName) ->
    supervisor:start_child(SupName, []).

%                           {Req:get(peer),
%                           {rabbit_socks_connection, start_link[Req:get(sock)]},
%                            transient, 5, worker, [rabbit_socks_connection]}).
