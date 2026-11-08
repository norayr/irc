# IRC client library

`IRC` is an Oberon IRC client library for VOC. It provides a lossless message
parser, registration and capability negotiation, SASL PLAIN, PING/PONG,
bounded outgoing queues, and reconnect handling. Applications own channel
policy, history, logging and user-interface behavior.

## Modules and dependencies

- `IRC`: parser and client state machine, using `Platform` and `oocStrings`.
- `IRCTCP`: Linux TCP transport using VOC's `Sockets` and `DNS` modules.
- `IRCTLS`: verified TLS 1.3 transport using `TLS13Live`'s resumable API.

The supported transport profile is Linux with VOC's model-2 sizes. The TLS
library must provide `Begin`, `PollHandshake`, `ReadSome`, `WriteSome` and
`CloseNow`. Certificate chains and hostnames are verified using the system
CA bundle, or the file selected by `SSL_CERT_FILE`. TLS 1.2 is unsupported.
The underlying pure-Oberon TLS arithmetic is not constant-time and has not
received an independent security audit.

## Building and testing

```sh
make
make tests
make example
```

`VOC` and `BUILD` are overridable. During development, the build uses
`../tls/src/TLS13Live.Mod` when available. Set `TLS_SOURCE=/path/to/TLS13Live.Mod`
to choose a source copy, or `TLS_SOURCE=` to use an updated installed VOC.
Rebuild dependent modules when updating the TLS state layout.

Tests use a fake transport and loopback servers. Python 3 and the OpenSSL
command-line tool are test dependencies; the library uses VOC's Oberon TLS
implementation. Tests cover parser errors, tags, one-byte I/O, queue limits,
blocked writes, deadlines, reconnects, SASL framing, TLS HelloRetryRequest,
and certificate/hostname rejection. `make example` builds `irctest`, whose
arguments are `host port nick channel`.

## Client API

```oberon
IRC.DefaultConfig(config);
config.host := "irc.libera.chat"; config.port := 6697;
config.nick := "myclient"; config.user := "myclient";
config.realName := "Oberon IRC client";
client := IRC.New(config, IRCTLS.New(), onMessage, onState);
IF IRC.Start(client) THEN
  WHILE client.state # IRC.Stopped DO
    IRC.Poll(client);
    (* application work *)
    Platform.Delay(10)
  END
END;
```

`Start` validates configuration. `Poll` advances connecting, registration,
reading and writing; `Stop` closes immediately, discards pending frames and
prevents reconnecting. `Loop` is a convenience polling loop that returns
when stopped. Callbacks receive the client, so several clients can share
one application loop. Callbacks must return promptly; recursive `Poll`
calls are ignored. This is a single-threaded API.

TCP connect, TLS handshake and established socket I/O are resumable. Host
resolution in `IRCTCP.Open` currently uses synchronous `DNS.Lookup`; DNS
timeouts can therefore delay the poll that starts a connection. Certificate
verification also performs synchronous computation and CA-file reading.
TLS handshakes are serialized by the underlying certificate parser;
established sessions can be polled independently. Callers should account
for these limits when integrating into a latency-sensitive event loop.

States are `Stopped`, `Waiting`, `Connecting`, `Registering` and `Ready`.
`onState` reports transitions and categorized errors. Network failures retry
with capped exponential backoff. Invalid configuration and authentication
failures stop. Nickname collisions retry; invalid nicknames stop. Rejected
joins are reported without disconnecting. The application receives the
original numeric reply as a message as well.

`Config` supplies connection, registration/PONG/write, idle and retry
intervals in milliseconds. Defaults are 30 seconds to connect, one minute
for replies/writes, four idle minutes before PING, and retries starting at
23 seconds and capped at five minutes.

`SendRaw` and `Privmsg` return whether a complete line entered the bounded
queue. They accept messages only in `Ready`; acceptance is not delivery
acknowledgement. Application traffic has a 56-frame limit, reserving eight
slots for control traffic. Control frames take priority after any partially
written frame. Invalid, injected or overlong output is rejected rather than
silently truncated. Applications can split long text on UTF-8 boundaries.
Queued frames are discarded on disconnect so stale commands are not replayed.

## Messages and authentication

`Message` exposes `raw`, raw `tags`, `prefix`, uppercase `command`, `count`,
all parameters, and whether the final parameter used a colon. Every parsed
message reaches `onMessage`, including unknown commands and numeric replies.
Messages retain their strings after the callback; applications may retain
copies of the record. `Parse` is independently usable. `Tag` decodes IRCv3
tag escapes, and `Nick` extracts the nickname from a prefix.

`SameName` and `IsChannel` use the server's `005 ISUPPORT` values for
`CASEMAPPING` and `CHANTYPES`; `nickLength` exposes `NICKLEN`. KICK, MODE,
TOPIC, INVITE and other commands are delivered without imposing application
policy. The classic message body limit is 510 bytes; incoming IRCv3 tags
have a separate bounded allowance.

Set `saslUser` and `saslPassword` to require SASL PLAIN. The client negotiates
CAP, sends 400-byte authentication chunks, waits for success, and then ends
capability negotiation. It stops on failure or missing SASL support, rather
than silently proceeding unauthenticated. PLAIN is refused on an unverified
transport unless `allowInsecureSASL` is explicitly enabled for controlled
environments. `password` is the separate IRC server PASS credential.

## License

Copyright (C) 2017–2026 Norayr Chilingarian. Licensed under GNU LGPL version 3
only (`LGPL-3.0-only`); see `LICENSE` and the incorporated GPL text in `COPYING`.
