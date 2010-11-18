-module(rabbit_socks_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 10, 10},
          [{rabbit_socks_listener_sup,
            {rabbit_socks_listener_sup, start_link, []},
            transient, 5, supervisor, [rabbit_socks_listener_sup]},
           {rabbit_socks_echo, {rabbit_socks_echo, start_link, []},
            transient, 5, supervisor, [rabbit_socks_connection_sup]},
           {rabbit_socks_stomp, {rabbit_socks_stomp, start_link, []},
            transient, 5, supervisor, [rabbit_socks_connection_sup]}]}}.
