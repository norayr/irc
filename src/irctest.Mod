MODULE irctest;
(* SPDX-License-Identifier: LGPL-3.0-only *)
IMPORT IRC, IRCTLS, Args, Out, IntStr, Strings := oocStrings, Platform;
VAR client: IRC.Client; config: IRC.Config; port: ARRAY 16 OF CHAR;
  room: ARRAY 128 OF CHAR; result: SHORTINT; ok: BOOLEAN;

PROCEDURE State(client: IRC.Client; state, error: INTEGER; detail: ARRAY OF CHAR);
VAR line: ARRAY 256 OF CHAR; accepted: BOOLEAN;
BEGIN
  Out.String(detail); Out.Ln;
  IF (state = IRC.Ready) & (error = 0) THEN
    COPY("JOIN ", line); Strings.Append(room, line); accepted := IRC.SendRaw(client, line)
  END
END State;

PROCEDURE Message(client: IRC.Client; VAR message: IRC.Message);
BEGIN Out.String(message.raw^); Out.Ln END Message;

PROCEDURE Interrupt(code: LONGINT);
BEGIN IF client # NIL THEN IRC.Stop(client) END; HALT(0) END Interrupt;

BEGIN
  IF Args.argc # 5 THEN Out.String("usage: irctest host port nick channel"); Out.Ln; HALT(3) END;
  IRC.DefaultConfig(config); Args.Get(1, config.host); Args.Get(2, port);
  Args.Get(3, config.nick); Args.Get(4, room); IntStr.StrToInt(port, config.port, result);
  IF result # 0 THEN HALT(3) END;
  config.user := config.nick; config.realName := "Oberon IRC example";
  client := IRC.New(config, IRCTLS.New(), Message, State);
  Platform.SetInterruptHandler(Interrupt); ok := IRC.Start(client); IRC.Loop(client)
END irctest.
