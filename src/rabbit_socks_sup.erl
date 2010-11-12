-module(rabbit_socks_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% TODO one connection supervisor for each backend
init([]) ->
    {ok, {{one_for_one, 10, 10},
          [{rabbit_socks_mochiweb, {rabbit_socks_mochiweb, start, []},
            transient, 5, worker, [rabbit_socks_mochiweb]},
           {rabbit_socks_echo, {rabbit_socks_echo, start_link, []},
            transient, 5, supervisor, [rabbit_socks_connection_sup]}]}}.
