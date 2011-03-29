-module(rabbit_socks_socketio2_sup).

-behaviour(supervisor).
-export([init/1]).

%%-------------------------

-export([start_link/0, start_child/1]).

%%--------------------------------------------------------------------

init([]) ->
    {ok, {{simple_one_for_one, 0, 1},
          [{undefined, {rabbit_socks_socketio2, start_link, []},
           transient, 50, worker, [rabbit_socks_socketio2]}]}}.

%%--------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Params) ->
    supervisor:start_child(?MODULE, [Params]).
