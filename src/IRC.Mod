MODULE IRC;

IMPORT Out, Files, Strings := oocStrings, Platform, Internet, Sockets, IntStr;

CONST
  msgLen* = 11711; (* receive buffer, including several IRC lines *)
  lineLen = 512; (* wire limit, including CRLF *)
  waitTime = 23000;
  cmdPing* = "PING";
  cmdPong* = "PONG";
  cmdMode* = "MODE";
  cmdJoin* = "JOIN";
  cmdUser* = "USER";
  cmdNick* = "NICK";
  msgPRIVMSG* = "PRIVMSG";
  msgNOTICE* = "NOTICE";
  msgQUIT* = "QUIT";
  msgJOIN* = "JOIN";
  msgPART* = "PART";
  ctcpChar* = 01X;
  msgACTION* = "ACTION";
  CR* = 0DX;
  LF* = 0AX;
  keepalive = "voc-keepalive";

TYPE
  chn* = ARRAY 128 OF CHAR;
  Channel* = RECORD
    channel*: chn;
    logfile: Files.File;
    rider: Files.Rider
  END;
  Channels* = POINTER TO ARRAY OF Channel;
  msg* = ARRAY msgLen OF CHAR;
  instance* = POINTER TO instanceDesc;
  cbPrivateMessage* = PROCEDURE(VAR inst: instance; VAR msg, msgtype, user, ident, host: ARRAY OF CHAR);
  cbPublicMessage* = PROCEDURE(VAR inst: instance; VAR msg, msgtype, user, ident, rcpt, host: ARRAY OF CHAR);
  cbPublicMessageWithMention* = PROCEDURE(VAR inst: instance; VAR msg, msgtype, user, ident, rcpt, host: ARRAY OF CHAR);
  cbIdle* = PROCEDURE(VAR inst: instance);
  instanceDesc* = RECORD
    owner-, user-, nick-, host-, port-, pass: chn;
    authenticate: BOOLEAN;
    connection*: Internet.Socket;
    channelList*: Channels;
    callbackPrivate*: cbPrivateMessage;
    callbackPublic*: cbPublicMessage;
    callbackPublicMention*: cbPublicMessageWithMention;
    callbackIdle*: cbIdle;
    doLog, authSent, registered, pingPending: BOOLEAN;
    pending: msg;
    pendingLen: INTEGER;
    connectedAt, lastReceived, pingSent: LONGINT;
    idleTimeout, replyTimeout, retryDelay: LONGINT
  END;

VAR eol-: ARRAY 3 OF CHAR;

PROCEDURE elapsed(since: LONGINT): LONGINT;
VAR now: LONGINT;
BEGIN
  now := Platform.Time();
  IF now < since THEN RETURN (MAX(LONGINT) - since) + now END;
  RETURN now - since
END elapsed;

(* RFC 1459 case folding for nicknames and channel names. *)
PROCEDURE fold(c: CHAR): CHAR;
BEGIN
  IF (c >= "a") & (c <= "z") THEN RETURN CAP(c) END;
  CASE c OF
    "{": RETURN "["
  | "}": RETURN "]"
  | "|": RETURN 5CX
  | "~": RETURN "^"
  ELSE RETURN c
  END
END fold;

PROCEDURE sameName(VAR left, right: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (left[i] # 0X) & (right[i] # 0X) & (fold(left[i]) = fold(right[i])) DO INC(i) END;
  RETURN left[i] = right[i]
END sameName;

PROCEDURE Disconnect*(VAR inst: instance);
BEGIN
  IF inst = NIL THEN RETURN END;
  IF inst.connection >= 0 THEN Internet.Disconnect(inst.connection) END;
  inst.connection := -1;
  inst.authSent := FALSE;
  inst.registered := FALSE;
  inst.pingPending := FALSE;
  inst.pendingLen := 0;
  inst.pending[0] := 0X
END Disconnect;

PROCEDURE Connect*(VAR inst: instance): BOOLEAN;
VAR socket: Sockets.Socket;
BEGIN
  Disconnect(inst);
  IF ~Internet.Connect(inst.host, inst.port, inst.connection) THEN RETURN FALSE END;
  (* Borrow the descriptor to enable polling through the VOC socket module. *)
  NEW(socket); socket.fd := inst.connection;
  IF ~Sockets.SetBlocking(socket, FALSE) THEN Disconnect(inst); RETURN FALSE END;
  inst.connectedAt := Platform.Time();
  inst.lastReceived := inst.connectedAt;
  RETURN TRUE
END Connect;

(* TRUE with an empty string means that the connection is idle, not closed. *)
PROCEDURE Receive*(VAR inst: instance; VAR str: ARRAY OF CHAR): BOOLEAN;
VAR n: LONGINT;
BEGIN
  IF LEN(str) < 2 THEN RETURN FALSE END;
  str[0] := 0X;
  IF inst.connection < 0 THEN RETURN FALSE END;
  n := Sockets.ReadDescriptor(inst.connection, str, 0, LEN(str) - 1);
  IF n > 0 THEN
    str[n] := 0X;
    inst.lastReceived := Platform.Time();
    RETURN TRUE
  END;
  IF Sockets.WouldBlock(n) OR Sockets.Interrupted(n) THEN RETURN TRUE END;
  Out.String("IRC: connection closed or read failed"); Out.Ln;
  Disconnect(inst);
  RETURN FALSE
END Receive;

PROCEDURE Send*(VAR inst: instance; str: ARRAY OF CHAR): BOOLEAN;
VAR done, n, length, started: LONGINT;
BEGIN
  IF inst.connection < 0 THEN RETURN FALSE END;
  done := 0; length := Strings.Length(str); started := Platform.Time();
  WHILE done < length DO
    n := Sockets.WriteDescriptor(inst.connection, str, done, length - done);
    IF n > 0 THEN INC(done, n)
    ELSIF Sockets.WouldBlock(n) OR Sockets.Interrupted(n) THEN
      IF elapsed(started) >= inst.replyTimeout THEN
        Out.String("IRC: write timed out"); Out.Ln;
        Disconnect(inst); RETURN FALSE
      END;
      Platform.Delay(10)
    ELSE
      Out.String("IRC: write failed"); Out.Ln;
      Disconnect(inst); RETURN FALSE
    END
  END;
  RETURN TRUE
END Send;

PROCEDURE Create*(owner, user, nick, host, port, pass: chn; auth: BOOLEAN;
    callBackPrv: cbPrivateMessage; callBackPbl: cbPublicMessage;
    callBackPblMn: cbPublicMessageWithMention): instance;
VAR inst: instance;
BEGIN
  NEW(inst);
  inst.owner := owner; inst.user := user; inst.nick := nick;
  inst.host := host; inst.port := port; inst.pass := pass;
  inst.authenticate := auth; inst.connection := -1;
  inst.callbackPrivate := callBackPrv;
  inst.callbackPublic := callBackPbl;
  inst.callbackPublicMention := callBackPblMn;
  inst.callbackIdle := NIL;
  inst.doLog := FALSE; inst.channelList := NIL;
  inst.idleTimeout := 240000; inst.replyTimeout := 60000; inst.retryDelay := waitTime;
  Disconnect(inst);
  RETURN inst
END Create;

(* Milliseconds: idle before PING, registration/PONG/write deadline, reconnect delay. *)
PROCEDURE setTimeouts*(VAR inst: instance; idle, reply, retry: LONGINT);
BEGIN
  IF idle > 0 THEN inst.idleTimeout := idle END;
  IF reply > 0 THEN inst.replyTimeout := reply END;
  IF retry >= 0 THEN inst.retryDelay := retry END
END setTimeouts;

PROCEDURE setLogging*(VAR inst: instance; state: BOOLEAN);
BEGIN
  inst.doLog := state
END setLogging;

PROCEDURE initChannelList*(VAR inst: instance; VAR channels: Channels);
VAR i: LONGINT;
BEGIN
  inst.channelList := channels;
  IF channels = NIL THEN RETURN END;
  FOR i := 0 TO LEN(channels^) - 1 DO
    channels[i].logfile := NIL;
    IF inst.doLog THEN
      channels[i].logfile := Files.Old(channels[i].channel);
      IF channels[i].logfile = NIL THEN channels[i].logfile := Files.New(channels[i].channel) END;
      IF channels[i].logfile # NIL THEN
        Files.Set(channels[i].rider, channels[i].logfile, Files.Length(channels[i].logfile))
      END
    END
  END
END initChannelList;

PROCEDURE Auth*(inst: instance): BOOLEAN;
VAR line: ARRAY lineLen + 1 OF CHAR;
BEGIN
  IF inst.authenticate & (inst.pass # "") THEN
    COPY("PASS ", line); Strings.Append(inst.pass, line); Strings.Append(eol, line);
    IF ~Send(inst, line) THEN RETURN FALSE END
  END;
  COPY("NICK ", line); Strings.Append(inst.nick, line); Strings.Append(eol, line);
  IF ~Send(inst, line) THEN RETURN FALSE END;
  COPY("USER ", line); Strings.Append(inst.user, line);
  Strings.Append(" 0 * :", line); Strings.Append(inst.owner, line); Strings.Append(eol, line);
  inst.authSent := Send(inst, line);
  RETURN inst.authSent
END Auth;

PROCEDURE Mode*(VAR inst: instance);
VAR line: ARRAY lineLen + 1 OF CHAR; b: BOOLEAN;
BEGIN
  COPY("MODE ", line); Strings.Append(inst.nick, line);
  Strings.Append(" +C", line); Strings.Append(eol, line);
  b := Send(inst, line)
END Mode;

PROCEDURE Join*(VAR inst: instance);
VAR line: ARRAY lineLen + 1 OF CHAR; i: LONGINT; b: BOOLEAN;
BEGIN
  IF inst.channelList = NIL THEN RETURN END;
  FOR i := 0 TO LEN(inst.channelList^) - 1 DO
    COPY("JOIN ", line); Strings.Append(inst.channelList[i].channel, line); Strings.Append(eol, line);
    b := Send(inst, line);
    IF ~b THEN RETURN END
  END
END Join;

PROCEDURE ModeAndJoin*(VAR inst: instance);
VAR line: ARRAY lineLen + 1 OF CHAR; b: BOOLEAN;
BEGIN
  COPY("MODE ", line); Strings.Append(inst.nick, line);
  Strings.Append(" +i", line); Strings.Append(eol, line);
  b := Send(inst, line);
  IF b THEN Join(inst) END
END ModeAndJoin;

PROCEDURE sendMsgToDst*(VAR inst: instance; VAR dst: ARRAY OF CHAR; msg: ARRAY OF CHAR);
VAR line: ARRAY lineLen + 1 OF CHAR; i, j: INTEGER; b: BOOLEAN;
BEGIN
  IF dst = "" THEN RETURN END;
  i := 0;
  WHILE dst[i] # 0X DO
    IF (dst[i] <= " ") OR (dst[i] = ":") THEN RETURN END;
    INC(i)
  END;
  IF i > lineLen - 12 THEN RETURN END;
  COPY("PRIVMSG ", line); Strings.Append(dst, line); Strings.Append(" :", line);
  i := Strings.Length(line); j := 0;
  WHILE (j < LEN(msg)) & (msg[j] # 0X) & (i < lineLen - 2) DO
    IF (msg[j] = CR) OR (msg[j] = LF) THEN line[i] := " " ELSE line[i] := msg[j] END;
    INC(i); INC(j)
  END;
  line[i] := 0X; Strings.Append(eol, line);
  b := Send(inst, line)
END sendMsgToDst;

(* Read one parameter; a leading colon makes the rest of the line one parameter. *)
PROCEDURE nextParam(VAR line: ARRAY OF CHAR; VAR pos: INTEGER; VAR value: ARRAY OF CHAR);
VAR start: INTEGER; trailing: BOOLEAN;
BEGIN
  WHILE line[pos] = " " DO INC(pos) END;
  trailing := line[pos] = ":";
  IF trailing THEN INC(pos) END;
  start := pos;
  WHILE (line[pos] # 0X) & (trailing OR (line[pos] # " ")) DO INC(pos) END;
  Strings.Extract(line, start, pos - start, value)
END nextParam;

PROCEDURE splitPrefix(VAR prefix, user, ident, host: ARRAY OF CHAR);
VAR bang, at: INTEGER; found: BOOLEAN;
BEGIN
  COPY(prefix, user); ident[0] := 0X; host[0] := 0X;
  Strings.FindNext("!", prefix, 0, found, bang);
  IF ~found THEN RETURN END;
  Strings.Extract(prefix, 0, bang, user);
  Strings.FindNext("@", prefix, bang + 1, found, at);
  IF ~found THEN RETURN END;
  INC(bang);
  IF prefix[bang] = "~" THEN INC(bang) END;
  Strings.Extract(prefix, bang, at - bang, ident);
  Strings.Extract(prefix, at + 1, Strings.Length(prefix) - at - 1, host)
END splitPrefix;

PROCEDURE formTimeString(VAR str: ARRAY OF CHAR);
VAR t, d: LONGINT; number: ARRAY 16 OF CHAR;

  PROCEDURE append(n: LONGINT; separator: ARRAY OF CHAR);
  BEGIN
    IntStr.IntToStr(n, number); Strings.Append(number, str); Strings.Append(separator, str)
  END append;

BEGIN
  Platform.GetClock(t, d); str[0] := 0X;
  append(2000 + d DIV 512, "-"); append(d DIV 32 MOD 16, "-"); append(d MOD 32, " (");
  append(t DIV 4096, ":"); append(t DIV 64 MOD 64, ":"); append(t MOD 64, ") ")
END formTimeString;

PROCEDURE log(VAR inst: instance; VAR message, command, user, rcpt: ARRAY OF CHAR);
VAR i: LONGINT; line, action: msg; found: BOOLEAN; pos, length: INTEGER;
BEGIN
  IF ~inst.doLog OR (inst.channelList = NIL) THEN RETURN END;
  IF (command # msgPRIVMSG) & (command # msgJOIN) & (command # msgPART) THEN RETURN END;
  FOR i := 0 TO LEN(inst.channelList^) - 1 DO
    IF sameName(inst.channelList[i].channel, rcpt) & (inst.channelList[i].logfile # NIL) THEN
      formTimeString(line);
      IF command = msgPRIVMSG THEN
        found := FALSE;
        IF message[0] = ctcpChar THEN
          Strings.FindNext("ACTION ", message, 1, found, pos);
          found := found & (pos = 1)
        END;
        IF found THEN
          length := Strings.Length(message);
          IF message[length - 1] = ctcpChar THEN DEC(length) END;
          Strings.Extract(message, 8, length - 8, action);
          Strings.Append("***", line); Strings.Append(user, line);
          Strings.Append(" ", line); Strings.Append(action, line)
        ELSE
          Strings.Append(user, line); Strings.Append(": ", line); Strings.Append(message, line)
        END
      ELSIF command = msgJOIN THEN
        Strings.Append(user, line);
        Strings.Append(" joined ", line); Strings.Append(rcpt, line)
      ELSE
        Strings.Append(user, line);
        Strings.Append(" left ", line); Strings.Append(rcpt, line)
      END;
      Files.WriteString(inst.channelList[i].rider, line);
      Files.Set(inst.channelList[i].rider, inst.channelList[i].logfile, Files.Pos(inst.channelList[i].rider) - 1);
      Files.Write(inst.channelList[i].rider, 10);
      Files.Register(inst.channelList[i].logfile);
      RETURN
    END
  END
END log;

PROCEDURE processLine(VAR inst: instance; VAR line: ARRAY OF CHAR);
VAR
  pos, start, i, mentionPos: INTEGER;
  prefix, user, ident, host, rcpt: chn;
  command: ARRAY 16 OF CHAR;
  message, reply: msg;
  mentioned, b: BOOLEAN;
BEGIN
  pos := 0; prefix[0] := 0X;
  IF line[pos] = "@" THEN (* IRCv3 message tags precede the prefix. *)
    WHILE (line[pos] # 0X) & (line[pos] # " ") DO INC(pos) END;
    WHILE line[pos] = " " DO INC(pos) END
  END;
  IF line[pos] = ":" THEN
    INC(pos); start := pos;
    WHILE (line[pos] # 0X) & (line[pos] # " ") DO INC(pos) END;
    Strings.Extract(line, start, pos - start, prefix)
  END;
  nextParam(line, pos, command);
  FOR i := 0 TO Strings.Length(command) - 1 DO
    IF (command[i] >= "a") & (command[i] <= "z") THEN command[i] := CAP(command[i]) END
  END;
  IF command = cmdPing THEN
    COPY(cmdPong, reply); Strings.Append(" ", reply);
    WHILE line[pos] = " " DO INC(pos) END;
    Strings.Extract(line, pos, Strings.Length(line) - pos, message);
    Strings.Append(message, reply); Strings.Append(eol, reply);
    b := Send(inst, reply); RETURN
  ELSIF command = cmdPong THEN
    REPEAT nextParam(line, pos, message) UNTIL line[pos] = 0X;
    IF message = keepalive THEN inst.pingPending := FALSE END;
    RETURN
  ELSIF command = "ERROR" THEN
    Out.String("IRC: "); Out.String(line); Out.Ln;
    Disconnect(inst); RETURN
  ELSIF command = "001" THEN
    nextParam(line, pos, rcpt);
    IF rcpt # "" THEN inst.nick := rcpt END;
    IF ~inst.registered THEN
      inst.registered := TRUE;
      Out.String("IRC: registered as "); Out.String(inst.nick); Out.Ln;
      ModeAndJoin(inst)
    END;
    RETURN
  END;
  splitPrefix(prefix, user, ident, host);
  IF command = cmdNick THEN
    nextParam(line, pos, rcpt);
    IF sameName(user, inst.nick) & (rcpt # "") THEN inst.nick := rcpt END;
    RETURN
  END;
  IF (command # msgPRIVMSG) & (command # msgNOTICE) & (command # msgJOIN) &
     (command # msgPART) & (command # msgQUIT) THEN RETURN END;
  rcpt[0] := 0X; message[0] := 0X;
  IF command = msgQUIT THEN nextParam(line, pos, message)
  ELSE
    nextParam(line, pos, rcpt);
    IF command # msgJOIN THEN nextParam(line, pos, message) END
  END;
  IF sameName(rcpt, inst.nick) THEN
    IF inst.callbackPrivate # NIL THEN inst.callbackPrivate(inst, message, command, user, ident, host) END
  ELSE
    log(inst, message, command, user, rcpt);
    mentioned := FALSE;
    IF (command = msgPRIVMSG) & (inst.nick # "") THEN
      Strings.FindNext(inst.nick, message, 0, mentioned, mentionPos)
    END;
    IF mentioned & (inst.callbackPublicMention # NIL) THEN
      (* Remove an addressing prefix only when it actually starts the message. *)
      IF mentionPos = 0 THEN
        i := Strings.Length(inst.nick);
        IF (message[i] = ":") OR (message[i] = ",") THEN INC(i) END;
        WHILE message[i] = " " DO INC(i) END;
        Strings.Delete(message, 0, i)
      END;
      inst.callbackPublicMention(inst, message, command, user, ident, rcpt, host)
    ELSIF inst.callbackPublic # NIL THEN
      inst.callbackPublic(inst, message, command, user, ident, rcpt, host)
    END
  END
END processLine;

(* TCP reads may end anywhere, or contain any number of complete IRC lines. *)
PROCEDURE processResponse(VAR inst: instance; VAR text: ARRAY OF CHAR);
VAR i: LONGINT; c: CHAR;
BEGIN
  i := 0;
  WHILE (text[i] # 0X) & (inst.connection >= 0) DO
    c := text[i]; INC(i);
    IF c = LF THEN
      IF (inst.pendingLen > 0) & (inst.pending[inst.pendingLen - 1] = CR) THEN DEC(inst.pendingLen) END;
      inst.pending[inst.pendingLen] := 0X;
      IF inst.pendingLen > 0 THEN processLine(inst, inst.pending) END;
      inst.pendingLen := 0
    ELSIF inst.pendingLen < msgLen - 1 THEN
      inst.pending[inst.pendingLen] := c; INC(inst.pendingLen)
    ELSE
      Out.String("IRC: incoming line exceeds receive buffer"); Out.Ln;
      Disconnect(inst)
    END
  END
END processResponse;

PROCEDURE checkTimeouts(VAR inst: instance);
VAR b: BOOLEAN; line: ARRAY 64 OF CHAR;
BEGIN
  IF inst.connection < 0 THEN RETURN END;
  IF ~inst.registered THEN
    IF elapsed(inst.connectedAt) < inst.replyTimeout THEN RETURN END;
    Out.String("IRC: registration timed out"); Out.Ln;
    Disconnect(inst)
  ELSIF inst.pingPending THEN
    IF elapsed(inst.pingSent) < inst.replyTimeout THEN RETURN END;
    Out.String("IRC: PONG timed out"); Out.Ln;
    Disconnect(inst)
  ELSIF elapsed(inst.lastReceived) >= inst.idleTimeout THEN
    COPY("PING :", line); Strings.Append(keepalive, line); Strings.Append(eol, line);
    b := Send(inst, line);
    IF b THEN inst.pingPending := TRUE; inst.pingSent := Platform.Time() END
  END
END checkTimeouts;

PROCEDURE Loop*(VAR inst: instance);
VAR text: msg; b: BOOLEAN;
BEGIN
  LOOP
    IF inst.connection < 0 THEN
      Out.String("IRC: connecting to "); Out.String(inst.host); Out.Ln;
      b := Connect(inst)
    END;
    IF (inst.connection >= 0) & ~inst.authSent THEN b := Auth(inst) END;
    IF inst.connection >= 0 THEN
      b := Receive(inst, text);
      IF b THEN processResponse(inst, text) END;
      checkTimeouts(inst);
      IF (inst.connection >= 0) & inst.registered & (inst.callbackIdle # NIL) THEN
        inst.callbackIdle(inst)
      END
    END;
    IF inst.connection < 0 THEN
      Out.String("IRC: retrying in "); Out.Int(inst.retryDelay DIV 1000, 0); Out.String(" seconds"); Out.Ln;
      Platform.Delay(inst.retryDelay)
    ELSE Platform.Delay(100)
    END
  END
END Loop;

PROCEDURE finalize*(VAR inst: instance);
VAR i, n: LONGINT; line: ARRAY 32 OF CHAR;
BEGIN
  IF inst = NIL THEN RETURN END;
  IF inst.channelList # NIL THEN
    FOR i := 0 TO LEN(inst.channelList^) - 1 DO
      IF inst.channelList[i].logfile # NIL THEN
        Files.Register(inst.channelList[i].logfile);
        Files.Close(inst.channelList[i].logfile);
        inst.channelList[i].logfile := NIL
      END
    END
  END;
  IF inst.connection >= 0 THEN
    COPY("QUIT :interrupt", line); Strings.Append(eol, line);
    (* Shutdown should stay prompt even when the peer has stopped reading. *)
    n := Sockets.WriteDescriptor(inst.connection, line, 0, Strings.Length(line))
  END;
  Disconnect(inst)
END finalize;

BEGIN
  eol[0] := CR; eol[1] := LF; eol[2] := 0X
END IRC.
