# Rabbit Socks

Support for communicating with RabbitMQ via [Websockets][ws] (v75 and v76,
covering Chrome 5+, Safari 5, and Firefox 4 beta) and Socket.IO
clients (covering much of the rest of the browser world).

## We've only just begun

Yes, it's early days; this _only just_ supports STOMP over Websockets, if you have the
RabbitMQ STOMP adapter too, and an echo "protocol". It works with
e.g., <http://github.com/jmesnil/stomp-websocket>.

Socket.IO support isn't running yet.  There's no configuration to
switch things off or listen on a different interface; and
it's potentially a security hole (though STOMP does require
authentication in the protocol).

## How to build it

Follow the usual kerfuffle given on
<http://www.rabbitmq.com/plugin-development.html>; summary:

    $ hg clone http://hg.rabbitmq.com/rabbitmq-public-umbrella
    $ cd rabbitmq-public-umbrella
    $ make co
    $ make
    $ hg clone http://hg.rabbitmq.com/rabbit-socks
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

You can browse to <http://localhost:5975/index.html> or
<http://localhost:5975/stomp.html> for demos. Note that they'll only
work for WebSockets-supporting browsers at the minute.

In general, Socks requires you to specify a (sub-)protocol. Since many
libraries don't support the <code>WebSocket-Protocol</code> (or
<code>Sec-WebSocket-Protocol</code>) header, it will also accept the
protocol in the URL: e.g.,

    var socket = new WebSocket('ws://localhost:5975/websocket/echo');

Paths starting with <code>/websocket/</code> will use bare WebSockets;
paths starting with <code>/socket.io/</code> will use Socket.IO's
protocol (which may also be via WebSockets ..) -- more info on the
latter when it's implemented.

[ws]: http://tools.ietf.org/html/draft-hixie-thewebsocketprotocol-76 "WebSockets draft v76"
