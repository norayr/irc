# IRC module

`IRC` is an Oberon IRC client module for VOC. It handles registration,
channel joining, PING/PONG, channel logs and message callbacks.

## Building

Install a current VOC with its `Internet`, `Sockets`, `oocStrings` and
`IntStr` modules, then run `make`. The resulting `build/IRC.o` and
`build/IRC.sym` can be used when compiling a client. `VOC` and `BUILD`
can be overridden on the make command line.

`make tests` compiles `src/irctest.Mod`, an interactive example. Running
`build/irctest` connects to the server and channels configured in that source.
The IRC history bot's `make tests` provides automated local-server regressions.

## Using the module

Create an instance with `Create`, configure its callbacks and channel list,
then call `Loop`. For channel logging, call `setLogging(inst, TRUE)` before
`initChannelList`. `src/irctest.Mod` demonstrates the setup.

`Loop` owns connecting, registration and reconnecting. It also accepts an
instance already connected with `Connect` and registered with `Auth`.
After each server welcome (`001`), it sets invisible mode and joins every
configured channel. Reconnects retain the channel list, log files and callbacks.

TCP fragments are buffered until a complete line arrives. Each line is
processed separately, so a PING is handled wherever it occurs in a read.
Outgoing commands use CRLF. `sendMsgToDst` replaces embedded line endings
with spaces and truncates the message to the 512-byte IRC wire limit.

EOF, read/write failures and server `ERROR` messages close the current
connection. The loop keeps retrying, with a default delay of 23 seconds.
An idle connection is checked with PING after four minutes; registration,
PONG and blocked writes have a one-minute deadline. `setTimeouts(inst,
idle, reply, retry)` changes these intervals in milliseconds. Establishing
the TCP connection itself uses `Internet.Connect` and its system timeout.

Callbacks should return promptly. An optional `callbackIdle` runs once per
loop iteration while registered; clients can use it to send paced replies
without blocking reception. `Receive` polls the socket: TRUE with an empty
string means no data is ready, and FALSE means the connection ended or failed.

Call `finalize` to flush and close logs and send QUIT. It is safe before
connecting or after a disconnect.
