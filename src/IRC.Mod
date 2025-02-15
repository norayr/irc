MODULE IRC; (*noch 23.2.2017 / 19.5.2017*)
IMPORT Out, Files, Strings := ooc2Strings, Platform,
       strUtils, netTypes, Internet, time, dbg;

CONST
  msgLen* = 11711; (* well irc msg len is 512, but we get in the buffer several messages. 11711 should be enough for 23 full lines *)
  waitTime = 23000; (* wait 23 seconds before reconnect *)
  (* irc commands *)
  cmdPing*      = "PING";
  cmdPong*      = "PONG";
  cmdMode*      = "MODE";
  cmdJoin*      = "JOIN";
  cmdUser*      = "USER";
  cmdNick*      = "NICK";
  msgPRIVMSG*   = "PRIVMSG";
  msgNOTICE*    = "NOTICE";
  msgQUIT*      = "QUIT";
  msgJOIN*      = "JOIN";
  msgPART*      = "PART";
  ctcpChar*     = 01X;
  msgACTION*    = "ACTION";
  (* irc replies rfc1459 from https://www.alien.net.au/irc/irc2numerics.html *)
  rplWelcome    = "001";
  rplYourHost   = "002";
  rplCreated    = "003";
  rplMyInfo     = "004";
  rplBounce     = "005";
  rplNameReply  = "353";
  rplEndOfNames = "366";

  CR* = 0DX;
  LF* = 0AX;

  eofMOTD="End of /MOTD";
  errClosingLink = "ERROR :Closing Link:";

  TYPE
    chn* = ARRAY 128 OF CHAR;

    Channel*   = RECORD
      channel* : chn;
      logfile : Files.File;
      rider   : Files.Rider;
    END;

    Channels* = POINTER TO ARRAY OF Channel;

    msg* = ARRAY msgLen OF CHAR;
    instance* = POINTER TO instanceDesc;
    (*cbMessage* = PROCEDURE(VAR msg : ARRAY OF CHAR);*) (* cb stands for callback *)
    cbPrivateMessage* = PROCEDURE (VAR inst: instance; VAR msg, msgtype, user, ident, host: ARRAY OF CHAR);
    cbPublicMessage*  = PROCEDURE (VAR inst: instance; VAR msg, msgtype, user, ident, rcpt, host: ARRAY OF CHAR);
    cbPublicMessageWithMention* = PROCEDURE(VAR inst: instance; VAR msg, msgtype, user, ident, rcpt, host: ARRAY OF CHAR); (* rcpt is usually the room in case of public messages *)

    instanceDesc* = RECORD
     owner-, user-, nick-, host-, port-, pass: chn;
     authenticate: BOOLEAN;
     connection*: Internet.Socket;
     channelList*: Channels;
     callbackPrivate*: cbPrivateMessage;
     callbackPublic*: cbPublicMessage;
     callbackPublicMention*: cbPublicMessageWithMention;
     doLog : BOOLEAN;
    END;


VAR
  eol- : ARRAY 3 OF CHAR;

PROCEDURE formTimeString(VAR str: ARRAY OF CHAR);
VAR
  year, month, day, hour, minute, second: LONGINT;
  syear, smonth, sday, shour, sminute, ssecond: ARRAY 8 OF CHAR;
BEGIN

  time.Now(year, month, day, hour, minute, second);
  strUtils.IntToStr(year, syear);
  strUtils.IntToStr(month, smonth);
  strUtils.IntToStr(day, sday);
  strUtils.IntToStr(hour, shour);
  strUtils.IntToStr(minute, sminute);
  strUtils.IntToStr(second, ssecond);

  COPY(syear, str);
  Strings.Append("-", str);
  Strings.Append(smonth, str);
  Strings.Append("-", str);
  Strings.Append(sday, str);
  Strings.Append(" (", str);
  Strings.Append(shour, str);
  Strings.Append(":", str);
  Strings.Append(sminute, str);
  Strings.Append(":", str);
  Strings.Append(ssecond, str);
  Strings.Append(") ", str);
END formTimeString;

PROCEDURE log(VAR inst: instance; message, messagetype, username, identname, rcpt: ARRAY OF CHAR);
VAR
  i : INTEGER;
  b : BOOLEAN;
  str: ARRAY msgLen OF CHAR;
  tmp: ARRAY 16 OF CHAR;
  (* for searching for ACTION *)
  b0: BOOLEAN;
  j:  INTEGER;
  str0: ARRAY msgLen OF CHAR;
BEGIN
  IF inst.doLog THEN
    strUtils.zeroStr(str);
    dbg.msg("logging about: "); Out.String(username); Out.String(", "); Out.String(messagetype); Out.String(", "); Out.String(rcpt); Out.Ln;
    i := 0; b := FALSE;
    REPEAT
      Out.String("is "); Out.String(inst.channelList^[i].channel); Out.String("="); Out.String(rcpt); Out.String("?"); Out.Ln;
      IF inst.channelList^[i].channel = rcpt THEN b := TRUE END;
      INC(i);
    UNTIL (i = LEN(inst.channelList^)) OR b;
    IF b THEN Out.String("yes!") ELSE Out.String("no!") END; Out.Ln;
    IF b OR (messagetype = msgPART) THEN (* we don't know from which channel user quits so we only write to log about it when he parts. *)
      DEC(i);
      formTimeString(str);
        IF messagetype = msgPRIVMSG THEN
          b0 := FALSE;
          Strings.FindNext(msgACTION, message, 1, b0, j);
          IF b0 THEN (* handle actions *)
            Strings.Append("***", str);
            Strings.Append(username, str);
            Strings.Append(" ", str);
            strUtils.getTillEOL(message, j+Strings.Length(msgACTION), str0);
            Strings.Append(str0, str);
          ELSE
            Strings.Append(username, str);
            tmp := ": ";
            Strings.Append(tmp, str);
            Strings.Append(message, str);
          END;
      ELSIF messagetype = msgJOIN THEN
        Strings.Append(username, str);
        tmp := " joined ";
        Strings.Append (tmp, str);
        Strings.Append (rcpt, str);
      ELSIF (messagetype = msgPART) THEN
        Strings.Append(username, str);
        tmp := " has quit";
        Strings.Append(tmp, str);
      END;
      Out.String("writing to "); Out.String(rcpt); Out.String(" log: "); Out.String(str); Out.Ln;
      Files.WriteString(inst.channelList^[i].rider, str);
      Files.Set(inst.channelList^[i].rider, inst.channelList^[i].logfile, Files.Pos(inst.channelList^[i].rider)-1); Files.Write(inst.channelList^[i].rider, 0AX);
      Files.Register(inst.channelList^[i].logfile);
    END;
  END; (* if do log *)
END log;

PROCEDURE Connect*(VAR inst: instance): BOOLEAN;
VAR
  res: BOOLEAN;
BEGIN
         dbg.enter("Connect");
  res := Internet.Connect(inst.host, inst.port, inst.connection);
  RETURN res
END Connect;

PROCEDURE Disconnect*(VAR inst: instance);
BEGIN
         dbg.enter("Disconnect");
  Internet.Disconnect(inst.connection);
END Disconnect;

PROCEDURE Receive*(VAR inst: instance; VAR str: ARRAY OF CHAR): BOOLEAN;
VAR
  b: BOOLEAN;
BEGIN
         dbg.enter("Receive");
  strUtils.zeroStr(str);
  b := Internet.Read(inst.connection, str);
     dbg.prnBool("received", b);
  RETURN b
END Receive;

PROCEDURE Send*(VAR inst: instance; str: ARRAY OF CHAR): BOOLEAN;
VAR
  b : BOOLEAN;
BEGIN
    dbg.enter("Send");
  b := Internet.Write(inst.connection, str);
       dbg.prnBool("wrote successfully", b);
       dbg.prnStr("whatever had to be sent", str);
  RETURN b
END Send;

PROCEDURE Pong(VAR inst: instance; VAR line: ARRAY OF CHAR);
VAR
  tmp: ARRAY msgLen OF CHAR;
  b : BOOLEAN;
BEGIN
      strUtils.cutLine(line, tmp);
      tmp[1] := 'O'; (* replace "PING" by "PONG" *)
      b := Send(inst, tmp);
END Pong;

PROCEDURE finalize*(VAR inst: instance);
VAR
  i: INTEGER;
  l: LONGINT;
  b: BOOLEAN;
  msg: ARRAY 23 OF CHAR;
BEGIN
  dbg.enter("finalize");
  IF inst.doLog THEN
    i := 0;
    REPEAT
           dbg.msg("flushing");
           dbg.prnStr("room", inst.channelList^[i].channel);
      Files.Register(inst.channelList^[i].logfile);
      Files.Close(inst.channelList^[i].logfile);
      INC(i)
    UNTIL i = LEN(inst.channelList^);
  END;
  msg := "QUIT :interrupt";
  l := Strings.Length(msg);
  msg[l] := LF;
  msg[l+1] := CR;
  msg[l+2] := 0X;
    dbg.msg("closing connection.");
    b := Send(inst, msg);
    dbg.prnBool("b", b);
  Disconnect(inst);
  Out.String("exiting."); Out.Ln;
END finalize;

PROCEDURE Create*(owner, user, nick, host, port, pass: chn; auth: BOOLEAN; callBackPrv: cbPrivateMessage; callBackPbl: cbPublicMessage; callBackPblMn: cbPublicMessageWithMention): instance;
VAR
  inst: instance;
BEGIN
    dbg.enter("Create");
  NEW(inst);
  inst.owner := owner;
  inst.user := user;
  inst.nick := nick;
  inst.host := host;
  inst.port := port;
  inst.pass := pass;
  inst.authenticate := auth;
  inst.callbackPrivate := callBackPrv;
  inst.callbackPublic := callBackPbl;
  inst.callbackPublicMention := callBackPblMn;
  RETURN inst
END Create;

PROCEDURE setLogging*(VAR inst: instance; state: BOOLEAN);
BEGIN
  inst.doLog := state;
END setLogging;

PROCEDURE formUserNickLine(VAR user, owner, nick, res: ARRAY OF CHAR);
VAR
  l : INTEGER;
BEGIN
  dbg.enter("formUserNickLine");
  COPY(cmdUser, res);
  Strings.Append(" ", res);
  Strings.Append(user, res);
  Strings.Append(" 0 * :", res);
  Strings.Append(owner, res);
  (* by the spec the command is terminated by \r\n *)

  l := Strings.Length(res);
  res[l] := LF;
  res[l+1] := CR;
  res[l+2] := 0X;
  (*Strings.Append(eol, res);*)

  Strings.Append (cmdNick, res);
  Strings.Append(" ", res);
  Strings.Append (nick, res);
  Strings.Append(eol, res);
END formUserNickLine;

PROCEDURE formModeLine(VAR str, nick: ARRAY OF CHAR);
BEGIN
               dbg.enter("formModeLine");
               dbg.prnStr("str", str);
               dbg.prnStr("nick", nick);

        COPY (cmdMode, str);
        Strings.Append(" ", str);
        Strings.Append(nick, str);
        Strings.Append(" +C", str);
        Strings.Append(eol, str);
               dbg.prnStr("str", str);
               dbg.prnStr("nick", nick);
END formModeLine;

PROCEDURE formJoinLine(VAR ln, chan: ARRAY OF CHAR);
BEGIN
        dbg.enter("formJoinLine");
        COPY(cmdJoin, ln);
        Strings.Append(" ", ln);
        Strings.Append(chan, ln);
        Strings.Append(eol, ln);
END formJoinLine;

PROCEDURE formModeJoinLine(VAR str, nick: ARRAY OF CHAR; channels: Channels);
VAR
  i: LONGINT;
BEGIN
        dbg.enter("formModeJoinLine");
        COPY (cmdMode, str);
        Strings.Append(" ", str);
        Strings.Append(nick, str);
        Strings.Append(" +i", str);
        strUtils.appendLFCR(str);
        (*Strings.Append(eol, str);*)

        i := 0;
        REPEAT
          Strings.Append(cmdJoin, str);
          Strings.Append(" ", str);
          Strings.Append(channels^[i].channel, str);
          INC(i);
          IF i = LEN(channels^) THEN
            Strings.Append(eol, str);
          ELSE
            strUtils.appendLFCR(str);
          END;
        UNTIL  i = LEN(channels^);
END formModeJoinLine;

PROCEDURE isPing(VAR line: ARRAY OF CHAR): BOOLEAN;
VAR
 tmp: ARRAY 5 OF CHAR;
 b: BOOLEAN;
BEGIN
    dbg.enter("isPing");
    Strings.Extract(line, 0, 4, tmp);
    dbg.compStrs(tmp, cmdPing);
    b := Strings.Equal(tmp, cmdPing);
    dbg.prnBool("b", b);
    RETURN b;
END isPing;

PROCEDURE isServerMsg(VAR line: ARRAY OF CHAR): BOOLEAN;
VAR
  b: BOOLEAN;
BEGIN
  dbg.enter("isServerMsg");
  b:= FALSE;
  IF LEN(line) >=1 THEN
    IF line[0] = ':' THEN b := TRUE END
  END;
  dbg.prnBool("is server msg", b);
  RETURN b;
END isServerMsg;

PROCEDURE error(VAR line: ARRAY OF CHAR): BOOLEAN;
VAR
  b : BOOLEAN;
  pos: INTEGER;
BEGIN
  dbg.enter("error");
  Strings.FindNext(errClosingLink, line, 0, b, pos);
  dbg.prnBool("found next errClosingLink", b);
  RETURN b
END error;

PROCEDURE initChannelList*(VAR inst: instance; VAR channels: Channels);
VAR
  i : INTEGER;
BEGIN
  IF inst.doLog THEN
    i := 0;
    REPEAT
      channels^[i].logfile := Files.Old(channels^[i].channel);
      IF channels^[i].logfile = NIL THEN
        channels^[i].logfile := Files.New(channels^[i].channel);
        Files.Set(channels^[i].rider, channels^[i].logfile, 0);
      ELSE
        Files.Set(channels^[i].rider, channels^[i].logfile, Files.Length(channels^[i].logfile));
      END;
            INC(i);
    UNTIL i = LEN(channels^);
  END;
  inst.channelList := channels;
END initChannelList;

PROCEDURE Auth*(inst: instance): BOOLEAN;
VAR
  line: ARRAY 255 OF CHAR;
  pass: ARRAY 16 OF CHAR;
  b : BOOLEAN;
BEGIN
  dbg.enter("Auth");
  IF inst.authenticate THEN
     IF inst.doLog THEN Out.String("Authenticating!"); Out.Ln END;
     COPY ("PASS ", pass);
     Strings.Append(inst.pass, pass);
     Strings.Append (eol, pass);
     b := Internet.Write(inst.connection, pass);
  END;

  formUserNickLine(inst.user, inst.owner, inst.nick, line);

  b := Internet.Write(inst.connection, line);

  RETURN b
END Auth;

PROCEDURE Mode*(VAR inst: instance);
VAR
  str : ARRAY msgLen OF CHAR;
  b : BOOLEAN;
BEGIN
        dbg.enter("Mode");
        strUtils.zeroStr(str);
        formModeLine(str, inst.nick);
        b := Send(inst, str);
END Mode;

PROCEDURE ModeAndJoin*(VAR inst : instance);
VAR str: ARRAY msgLen OF CHAR;
    b: BOOLEAN;
BEGIN
         dbg.enter("ModeAndJoin");
         strUtils.zeroStr(str);
         formModeJoinLine(str, inst.nick, inst.channelList);
         b := Send(inst, str);
END ModeAndJoin;

PROCEDURE Join*(VAR inst: instance);
VAR
  str: ARRAY msgLen OF CHAR;
  b: BOOLEAN;
BEGIN
  dbg.enter("Join");
  strUtils.zeroStr(str);
  formJoinLine(str, inst.channelList^[0].channel);
  Out.String("SENDING JOIN LINE"); Out.Ln;
  b := Send(inst, str);
END Join;

PROCEDURE getUser(VAR line, user: ARRAY OF CHAR): BOOLEAN;
VAR
  pos: INTEGER;
  found: BOOLEAN;
BEGIN
  dbg.enter("getUser");
  dbg.prnStr("line", line); dbg.prnStr("user", user);
  strUtils.zeroStr(user);
  Strings.FindNext(" ", line, 1, found, pos);
  IF found THEN
    Strings.Extract(line, 1, pos - 1, user);
  END;
  dbg.prnStr("line", line); dbg.prnStr("user", user);
  RETURN found
END getUser;

PROCEDURE getMsgType(VAR line, mtype: ARRAY OF CHAR): BOOLEAN;
VAR
  pos0, pos1: INTEGER;
  found: BOOLEAN;
BEGIN
  dbg.enter("getMsgType");
  dbg.prnStr("line", line); dbg.prnStr("mtype", mtype);
  strUtils.zeroStr(mtype);
  Strings.FindNext(" ", line, 0, found, pos0);
  IF found THEN
     Strings.FindNext(" ", line, pos0+1, found, pos1);
     IF found THEN
       Strings.Extract(line, pos0 + 1, pos1 - pos0 - 1, mtype);
     END;
  END;
  dbg.prnStr("line", line); dbg.prnStr("mtype", mtype);
  dbg.prnBool("found", found);
  RETURN found
END getMsgType;

PROCEDURE getRecipient(VAR line, room: ARRAY OF CHAR): BOOLEAN;
VAR
  pos0, pos1: INTEGER;
  found: BOOLEAN;
BEGIN
  dbg.enter("getRecipient");
  dbg.prnStr("line", line); dbg.prnStr("room", room);
  strUtils.zeroStr(room);
  Strings.FindNext(" ", line, 0, found, pos1);
  IF found THEN
     Strings.FindNext(" ", line, pos1+1, found, pos0);
     IF found THEN
       strUtils.getNextWord(line, pos0+1, room);
     END;
  END;
  dbg.prnStr("line", line); dbg.prnStr("room", room);
  dbg.prnBool("found", found);
  RETURN found
END getRecipient;

PROCEDURE getMsg(VAR line, msg: ARRAY OF CHAR): BOOLEAN;
VAR
  pos0, pos1: INTEGER;
  found: BOOLEAN;
BEGIN
  dbg.enter("getMsg");
  dbg.prnStr("line", line); dbg.prnStr("msg", msg);
  strUtils.zeroStr(msg);
  Strings.FindNext(" ", line, 0, found, pos0);
  IF found THEN
     Strings.FindNext(" ", line, pos0+1, found, pos1);
     IF found THEN
        Strings.FindNext(" ", line, pos1+1, found, pos0);
        strUtils.getTillEOL(line, pos0+1, msg);
     END;
  END;
  dbg.prnStr("line", line); dbg.prnStr("msg", msg);
  dbg.prnBool("found", found);
  RETURN found
END getMsg;

PROCEDURE getUserName(VAR user, username: ARRAY OF CHAR): BOOLEAN;
VAR
  i: INTEGER;
  b: BOOLEAN;
BEGIN
  dbg.enter("getUserName");
  dbg.prnStr("user", user); dbg.prnStr("username", username);
  strUtils.zeroStr(username);
  Strings.FindNext("!", user, 0, b, i);
  IF b THEN
    Strings.Extract(user, 0, i, username);
  END;
  dbg.prnStr("user", user); dbg.prnStr("username", username);
  dbg.prnBool("b", b);
  RETURN b
END getUserName;

PROCEDURE getIdentName(VAR user, ident: ARRAY OF CHAR): BOOLEAN;
VAR
  i, j: INTEGER;
  b: BOOLEAN;
BEGIN
  dbg.enter("getIdentName");
  dbg.prnStr("user", user); dbg.prnStr("ident", ident);
  dbg.msg("clearing ident");
  strUtils.zeroStr(ident);
  dbg.prnStr("user", user); dbg.prnStr("ident", ident);
  Strings.FindNext("~", user, 0, b, i);
  IF b THEN
    Strings.FindNext("@", user, i, b, j);
    IF b THEN
      Strings.Extract(user, i+1, j-i-1, ident);
    END;
  END;
  dbg.prnStr("user", user); dbg.prnStr("ident", ident);
  dbg.prnBool("b", b);
  RETURN b;
END getIdentName;

PROCEDURE getHost(VAR user, host: ARRAY OF CHAR): BOOLEAN;
VAR
  i: INTEGER;
  b: BOOLEAN;
BEGIN
  dbg.enter("getHost");
  dbg.prnStr("user", user); dbg.prnStr("host", host);
  dbg.msg("clearing host");
  strUtils.zeroStr(host);
  Strings.FindNext("@", user, 0, b, i);
  IF b THEN
    Strings.Extract(user, i+1, Strings.Length(user)-i-1, host);
  END;
  dbg.prnStr("user", user); dbg.prnStr("host", host);
  dbg.prnBool("b", b);
  RETURN b;
END getHost;

PROCEDURE isMention(VAR nick, line: ARRAY OF CHAR): BOOLEAN;
VAR
  i : INTEGER;
  b: BOOLEAN;
BEGIN
  b := FALSE;
  dbg.enter("isMention");
  dbg.prnStr("nick", nick); dbg.prnStr("line", line);
  Strings.FindNext(nick, line, 0, b, i);
  dbg.prnBool("mentioned", b);
  RETURN b;
END isMention;

PROCEDURE cutMentionFromMessage(VAR nick, msg: ARRAY OF CHAR);
BEGIN
  dbg.enter("cutMentionFromMessage");
  dbg.prnStr("nick", nick);
  dbg.prnStr("msg", msg);
  Strings.Delete(msg, 0, Strings.Length(nick) + 2);
  dbg.prnStr("nick", nick);
  dbg.prnStr("msg", msg);
END cutMentionFromMessage;

PROCEDURE sendMsgToDst*(VAR inst: instance; VAR dst: ARRAY OF CHAR; msg: ARRAY OF CHAR);
VAR
  s: POINTER TO ARRAY OF CHAR;
  i, j: LONGINT;
  b: BOOLEAN;
BEGIN
  dbg.enter("cutMentionFromMessage");
  i := Strings.Length(msg);
  j := Strings.Length(dst);
  NEW(s, i + j + Strings.Length(msgPRIVMSG) + 6(* to fit a colon and two spaces  and eol *));
  COPY(msgPRIVMSG, s^);
  Strings.Append(' ', s^);
  Strings.Append(dst, s^);
  Strings.Append(' :', s^);
  Strings.Append(msg, s^);
  strUtils.appendLFCR(s^);
  Out.String("sending: "); Out.String(s^); Out.Ln;
  b := Send(inst, s^);
END sendMsgToDst;

PROCEDURE  processFurther(VAR inst: instance; VAR line: ARRAY OF CHAR);
VAR
  message: ARRAY msgLen OF CHAR;
  userpart, username, identname   : ARRAY 64 OF CHAR;
  host: ARRAY 64 OF CHAR;
  messagetype: ARRAY 16 OF CHAR;
  rcpt: ARRAY 64 OF CHAR;
  b: BOOLEAN;
  mn: BOOLEAN;
  i: INTEGER;
BEGIN
  dbg.enter("processFurther");
  dbg.prnStr("line", line);
  i := 0; mn := FALSE; b := FALSE;
  b := getUser(line, userpart);
  b := getMsgType(line, messagetype);

  IF (messagetype = msgNOTICE) OR (messagetype = msgJOIN) OR
     (messagetype = msgQUIT)   OR (messagetype = msgPRIVMSG) OR
     (messagetype = msgPART) THEN

     IF messagetype = msgPRIVMSG THEN
        b := getUserName(userpart, username);
        b := getIdentName(userpart, identname);
        b := getHost(userpart, host);
        b := getRecipient(line, rcpt);
        b := getMsg(line, message);
     END;

     IF messagetype = msgNOTICE THEN
        username := "";
        identname := "";
        host := userpart;
        IF host[0] = ':' THEN Strings.Delete(host, 0, 1); END;
        b := getRecipient(line, rcpt);
        b := getMsg(line, message);
     END;

     IF messagetype = msgJOIN THEN
        b := getUserName(userpart, username);
        b := getIdentName(userpart, identname);
        b := getHost(userpart, host);
        b := getRecipient(line, rcpt);
        message := "";
     END;

     IF (messagetype = msgQUIT) THEN
        b := getUserName(userpart, username);
        b := getIdentName(userpart, identname);
        b := getHost(userpart, host);
        rcpt := "";
        message := "";
        Strings.FindNext(":", line, 1, b, i);
        strUtils.getTillEOL(line, i, message);
     END;

     IF (messagetype = msgPART) THEN
        b := getUserName(userpart, username);
        b := getIdentName(userpart, identname);
        b := getHost(userpart, host);
        b := getRecipient(line, rcpt);
        message := "";
     END;

     IF rcpt = inst.nick THEN (* private message *)
       inst.callbackPrivate(inst, message, messagetype, username, identname, host);
     ELSE
       mn := isMention(inst.nick, message);
       IF mn THEN
         log(inst, message, messagetype, username, identname, rcpt);
         cutMentionFromMessage(inst.nick, message);
         inst.callbackPublicMention(inst, message, messagetype, username, identname, rcpt, host);
       ELSE
         log(inst, message, messagetype, username, identname, rcpt);
         inst.callbackPublic(inst, message, messagetype, username, identname, rcpt, host);
       END;
     END;
  ELSE
     Out.String("unknown msg type: '"); Out.String(messagetype); Out.String("' - ignoring!"); Out.Ln;
  END;
END processFurther;

PROCEDURE processLineByLine(VAR inst: instance; VAR text: ARRAY OF CHAR);
VAR
  i : INTEGER;
  pstrs: strUtils.pstrings;
BEGIN
  dbg.enter("processLineByLine");
  pstrs := strUtils.string2pstrings(text);
  dbg.prnPstrings("pstrs", pstrs);
  i := 0;
  REPEAT
     processFurther(inst, pstrs^[i]^);
     INC(i)
  UNTIL i = LEN(pstrs^);
END processLineByLine;

PROCEDURE doesLineContainPattern(VAR text: ARRAY OF CHAR; pattern: ARRAY OF CHAR; column: INTEGER): BOOLEAN;
VAR
  parts: strUtils.pstrings;
  code: strUtils.pstring;
  b: BOOLEAN;
BEGIN
  dbg.enter("doesLineContainPattern");
  b := FALSE;
  (* Split 'text' into parts based on spaces *)
  parts := strUtils.tokenize(text, ' ');
  dbg.prnPstrings("parts", parts);
  (* Check if the message has enough parts to be a valid IRC message *)
  IF parts # NIL THEN
    IF LEN(parts^) >= column THEN
      code := parts^[column-1];
      dbg.compStrs(code^, pattern);
      b :=Strings.Compare(code^, pattern) = 0;
      dbg.prnBool("same", b);
    END;
  END;
  RETURN b;
END doesLineContainPattern;

PROCEDURE isWelcomeMessage(VAR text: ARRAY OF CHAR): BOOLEAN;
VAR
  i : INTEGER;
  pstrs: strUtils.pstrings;
  r: BOOLEAN;
BEGIN
  dbg.enter("isWelcomeMessage");
  r := FALSE;
  pstrs := strUtils.string2pstrings(text);
  dbg.prnPstrings("pstrs", pstrs);
  i := 0;
  IF pstrs # NIL THEN
    REPEAT
       dbg.enterLoop("will check if welcome message every line");
       r := doesLineContainPattern(pstrs^[i]^, rplWelcome, 2);
       INC(i)
    UNTIL r OR (i = LEN(pstrs^));
    dbg.exitLoop("exited the loop");
  END;
    RETURN r
END isWelcomeMessage;

PROCEDURE processResponse(VAR inst: instance; VAR text: ARRAY OF CHAR): BOOLEAN;
VAR
  b : BOOLEAN;
BEGIN
  dbg.enter("processResponse");
  b := TRUE;
  IF isPing(text) THEN
    Pong(inst, text);
  END;
  IF error(text) THEN
    (* Disconnect on error to allow reconnection *)
    Disconnect(inst);
    b := FALSE;
  ELSE
    IF isServerMsg(text) THEN (* string starts with ':' *)
      IF isWelcomeMessage(text) THEN
         ModeAndJoin(inst);
      ELSE
         processLineByLine(inst, text);
      END;
    END;
  END;
  RETURN b;
END processResponse;

PROCEDURE Loop*(VAR inst: instance);
CONST numOfFailed = 1024;
VAR
  b, b2 : BOOLEAN;
  txt : ARRAY msgLen OF CHAR;
  i: INTEGER;
  connected: BOOLEAN;
BEGIN
  dbg.enter("Loop");
  i := 0;
  connected := FALSE;

  WHILE i < numOfFailed DO
    IF ~connected THEN
      (* Attempt to connect *)
      Disconnect(inst); (* Ensure previous connection is closed *)
      connected := Connect(inst);
      IF connected THEN
        (* Authenticate and reset failure counter *)
        IF Auth(inst) THEN
          i := 0; (* Reset failure counter on successful auth *)
        ELSE
          connected := FALSE; (* Auth failed *)
        END;
      END;
      IF ~connected THEN
        Platform.Delay(waitTime);
        INC(i);
        CONTINUE;
      END;
    END;

    (* Process messages while connected *)
    b := Receive(inst, txt);
    IF b THEN
      b2 := processResponse(inst, txt);
      IF ~b2 THEN
        (* Error in processing, disconnect *)
        Disconnect(inst);
        connected := FALSE;
        Platform.Delay(waitTime);
        INC(i);
      END;
    ELSE
      (* Receive failed, disconnect *)
      Disconnect(inst);
      connected := FALSE;
      Platform.Delay(waitTime);
      INC(i);
    END;
  END; (* WHILE *)
END Loop;

BEGIN
  eol[0] := LF; eol[1] := CR;
  dbg.setDebug(TRUE);
END IRC.
