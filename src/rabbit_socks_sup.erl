-module(rabbit_socks_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SocketioSup = {rabbit_socks_socketio_sup,
                   {rabbit_socks_socketio_sup, start_link, []},
                   transient, 5, supervisor, [rabbit_socks_socketio]},

    {ok, {{one_for_one, 10, 10},
          [{rabbit_socks_listener_sup,
            {rabbit_socks_listener_sup, start_link, []},
            transient, 5, supervisor, [rabbit_socks_listener_sup]},
           {rabbit_socks_websockets, {rabbit_socks_connection_sup, start_link, [rabbit_socks_ws_connection]},
            transient, 5, supervisor, [rabbit_socks_connection_sup]},
           {rabbit_socks_xhrpolling, {rabbit_socks_connection_sup, start_link, [rabbit_socks_xhrpolling]},
            transient, 5, supervisor, [rabbit_socks_connection_sup]},
           SocketioSup
          ]}}.
