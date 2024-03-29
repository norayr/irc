MODULE irctest; (* noch 13.4.2017 / 18.5.2017*)

IMPORT IRC, Out, Strings := ooc2Strings, Platform;

(* i am moving these to global section to make possible for interrupt handler to access instance *)
VAR
  inst: IRC.instance;
  channels : IRC.Channels;
  b: BOOLEAN;


(*
PROCEDURE onMessage(VAR msg : ARRAY OF CHAR);
BEGIN
   Out.String("callback procedure is running, youhoo!"); Out.Ln;
   Out.String("input:"); Out.Ln;
   Out.String(msg); Out.String("|"); Out.Ln;
   Out.Ln;
END onMessage;
*)
PROCEDURE onPrivateMessage(VAR inst: IRC.instance; VAR msg, msgtype, user, ident, host: ARRAY OF CHAR);
BEGIN
  Out.String("*** private message ***"); Out.Ln;
  Out.String("message: '"); Out.String(msg); Out.Char("'"); Out.Ln;
  Out.String("message type: '"); Out.String(msgtype); Out.Char("'"); Out.Ln;
  Out.String("user: '"); Out.String(user); Out.Char("'"); Out.Ln;
  Out.String("ident: '"); Out.String(ident); Out.Char("'"); Out.Ln;
  Out.String("host: '"); Out.String(host); Out.Char("'"); Out.Ln;
  Out.String("*** that's it ***"); Out.Ln;
  IRC.sendMsgToDst(inst, user, "hello, nice to meet you");
END onPrivateMessage;

PROCEDURE onPublicMessage(VAR inst: IRC.instance; VAR msg, msgtype, user, ident, rcpt, host: ARRAY OF CHAR);
BEGIN
  Out.String("*** public message ***"); Out.Ln;
  Out.String("message: '"); Out.String(msg); Out.Char("'"); Out.Ln;
  Out.String("message type: '"); Out.String(msgtype); Out.Char("'"); Out.Ln;
  Out.String("user: '"); Out.String(user); Out.Char("'"); Out.Ln;
  Out.String("ident: '"); Out.String(ident); Out.Char("'"); Out.Ln;
  Out.String("recipient: '"); Out.String(rcpt); Out.Char("'"); Out.Ln;
  Out.String("host: '"); Out.String(host); Out.Char("'"); Out.Ln;
  Out.String("*** that's it ***"); Out.Ln;
  IF msgtype # IRC.msgJOIN THEN IRC.sendMsgToDst(inst, rcpt, "test back") END;
END onPublicMessage;

PROCEDURE onPublicMessageWithMention(VAR inst: IRC.instance; VAR msg, msgtype, user, ident, rcpt, host: ARRAY OF CHAR);
BEGIN
  Out.String("*** public message, bot name mentioned ***"); Out.Ln;
  Out.String("message: '"); Out.String(msg); Out.Char("'"); Out.Ln;
  Out.String("message type: '"); Out.String(msgtype); Out.Char("'"); Out.Ln;
  Out.String("user: '"); Out.String(user); Out.Char("'"); Out.Ln;
  Out.String("ident: '"); Out.String(ident); Out.Char("'"); Out.Ln;
  Out.String("recipient: '"); Out.String(rcpt); Out.Char("'"); Out.Ln;
  Out.String("host: '"); Out.String(host); Out.Char("'"); Out.Ln;
  Out.String("*** that's it ***"); Out.Ln;
END onPublicMessageWithMention;

PROCEDURE interrupt(i: LONGINT);
BEGIN
(* here we need to flush files to disk before exiting. and probably close the irc connection *)
   Out.String("interrupt caught."); Out.Ln;
   IRC.finalize(inst);
   HALT(0);
END interrupt;

BEGIN
  (* should call
  Create(owner: chn; user: chn; nick: chn; host: chn; port: chn; pass: chn; auth: BOOLEAN; callBackPrv: cbPrivateMessage; callBackPbl: cbPublicMessage; callBackPblMn: cbPublicMessageWithMention): instance;
  *)
  inst := IRC.Create("norayr_tanakian", "norayr_tanakian", "oberonbot", "irc.libera.chat", "6667", "aaa", FALSE, onPrivateMessage, onPublicMessage, onPublicMessageWithMention);
  (* old usage
  inst.owner := "norayr_tanakian";
  inst.user := "norayr_tanakian";
  inst.nick := "vocbot";
  inst.host := "irc.freenode.net";
  inst.port := "6667";
  inst.callbackPrivate := onPrivateMessage;
  inst.callbackPublic := onPublicMessage;
  inst.callbackPublicMention := onPublicMessageWithMention;
  *)


  NEW(channels, 1);
  channels[0].channel := "#oberon-test";
  IRC.setLogging(inst, TRUE);
  IRC.initChannelList(inst, channels);

  Platform.SetInterruptHandler(interrupt);

  IF IRC.Connect(inst) # FALSE THEN
    b := IRC.Auth(inst);
    IRC.Loop(inst);
  END;

END irctest.

