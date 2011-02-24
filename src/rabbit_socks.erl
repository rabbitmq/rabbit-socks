-module(rabbit_socks).

-behaviour(application).

-export([start/2, stop/1]).

start(normal, []) ->
    {ok, SupPid} = rabbit_socks_sup:start_link(),
    case application:get_env(listeners) of
        undefined ->
            throw({error, socks_no_listeners_given});
        {ok, Listeners} ->
            error_logger:info_msg("Starting ~s~nbinding to:~n~p",
                                  ["Rabbit Socks", Listeners]),
            ok = rabbit_socks_mochiweb:start(Listeners)
    end,
    {ok, SupPid}.

stop(_State) ->
    ok.
