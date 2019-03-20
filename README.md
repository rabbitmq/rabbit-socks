# Rabbit Socks

Support for communicating with RabbitMQ via [Websockets][ws] (v75 and v76,
covering Chrome 5+, Safari 5, and Firefox 4 beta) and Socket.IO
clients (covering much of the rest of the browser world).

## We've only just begun

Yes, it's early days. WebSockets draft 76 is supported; Socket.IO
support is limited to XHR-polling.

## How to build it

Follow the usual kerfuffle given on
<https://www.rabbitmq.com/plugin-development.html>; summary:

    $ hg clone https://hg.rabbitmq.com/rabbitmq-public-umbrella
    $ cd rabbitmq-public-umbrella
    $ make co
    $ make
    $ hg clone https://hg.rabbitmq.com/rabbit-socks
    $ cd rabbit-socks
    $ make
    $ cd ../rabbitmq-server
    $ mkdir -p plugins; cd plugins
    $ cp ../../rabbitmq-stomp/dist/*.ez ./
    $ cp ../../rabbit-socks/dist/*.ez ./
    $ rm rabbit_common.ez
    $ cd ..; make run

There -- easy!

## How to use it

By default there are no listeners configured. You can start one
through configuration or programmatically (e.g., from your own Erlang
app).

### Configuration

Rabbit Socks will start listeners specified in the environment entry
`'listeners'`. By default this is an empty list. The syntax for a
listener is

    Listener = {Interface, Module, Options}

    Interface = rabbit_mochiweb
              | Port
              | {IpAddress, Port}

    Options = []
            | [Option | Options]

`Port` is a port number, of course; `Module` is a callback module,
e.g., `'rabbit_socks_echo'`. The options are passed through to
mochiweb.

If `'rabbit_mochiweb'` is supplied as the interface, the listener will
be registered with [RabbitMQ's Mochiweb
plugin](https://www.rabbitmq.com//mochiweb.html) in the context
`'socks'`.

As usual, you can supply such a configuration on the command line:

    $ erl -rabbit_socks listeners [{rabbit_mochiweb, rabbit_socks_echo, []}]

or in a [config file](https://www.erlang.org/doc/man/config.html).

### From code

    rabbit_socks:start_listener(Interface, Module, Options).

with the meanings as given above.

## URLs

A listener serves two kinds of path: paths starting with `/websocket/`
will use bare WebSockets; paths starting with `/socket.io/` will use
Socket.IO's protocol (which may also be via WebSockets).

The path after that prefix is given to the callback module.

## Callback modules

A callback module must define these procedures:

 - `subprotocol_name()`: the name of the subprotocol, to be sent in
    the connection establishment headers.

 - `init(Path, [])`: is given the path and, for a callback module, an
    empty list (yes this is a wart). It should return `{ok, State}` if
    the connection can go ahead; the State will be supplied on
    subsequent calls.

 - `open(WriterModule, WriterArg, State)`: this is called when the
   connection has been opened. `WriterModule` and `WriterArg` are used
   to send data, so you should probably keep them in the state. It
   should return `{ok, NewState}`.

 - `handle_frame(Frame, State)`: this is called when a frame is
   received, and should return `{ok, NewState}`.

 - `terminate(State)` is called if the connection is closed from the
   client end. It should return `'ok'`.

Returning `{error, Reason}` at any point will shut the connection
down.

[ws]: https://tools.ietf.org/html/draft-hixie-thewebsocketprotocol-76 "WebSockets draft v76"
