-module(rabbit_socks).

%% TODO
%% The application.  Reads the configuration and starts things
%% appropriately.  There are transports and backends. Transports are
%% e.g., websockets-with-mochiweb. Backends are e.g.,
%% rabbit_stomp. The configuration specifies how to listen and for
%% what.

-behaviour(application).

-export([start/2, stop/1]).

start(normal, []) ->
    rabbit_socks_sup:start_link().

stop(_State) ->
    ok.
