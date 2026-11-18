unit ChatMail;

{ Mail from the site: address checks, password links, missed messages
  (ChatMissed) and bug reports.  Plain SMTP over TLS
  (port 465) with fcl-net's sockets, signed in to a mailbox:

    [mail]
    host=mail.example.com
    port=465
    user=chat@example.com
    password=...
    from=chat@example.com
    name=Example Chat

  With no host set, nothing is sent and SendMail says so. }

{$mode objfpc}{$H+}

interface

{ Sends a plain text mail; False (and the reason in the log) when it did
  not go.  Headers: more header lines, each ending in CR LF. }
function SendMail(const ToAddress, Subject, Body: string; const Headers: string = ''): boolean;
function MailReady: boolean;

implementation

uses
  Classes, SysUtils, base64, ssockets, sslsockets, opensslsockets, ChatDb, ChatUsers, ChatTls;

function MailReady: boolean;
begin
  Result := Config.ReadString('mail', 'host', '') <> '';
end;

{ The server's answer: its lines until the one with a space after the code. }
function Answer(Sock: TSocketStream): string;
var
  C: char;
  Line: string;
begin
  Result := '';
  repeat
    Line := '';
    repeat
      if Sock.Read(C, 1) <> 1 then
        raise Exception.Create('the mail server hung up');
      if C <> #13 then
        Line := Line + C;
    until C = #10;
    Result := Result + Line;
  until (Length(Line) < 4) or (Line[4] = ' ');
end;

procedure Expect(Sock: TSocketStream; const Command, Code: string);
var
  Data, Got: string;
begin
  if Command <> '' then
  begin
    Data := Command + #13#10;
    Sock.WriteBuffer(Data[1], Length(Data));
  end;
  Got := Answer(Sock);
  if not Got.StartsWith(Code) then
    raise Exception.Create(Trim(Got));
end;

{ The body with lines that start with a dot doubled (RFC 5321 4.5.2). }
function DotStuffed(const Body: string): string;
var
  Lines: TStringList;
  I: integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Body;
    for I := 0 to Lines.Count - 1 do
      if Lines[I].StartsWith('.') then
        Lines[I] := '.' + Lines[I];
    Lines.LineBreak := #13#10;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function SendMail(const ToAddress, Subject, Body: string; const Headers: string): boolean;
var
  Sock: TInetSocket;
  Handler: TSSLSocketHandler;
  From, Name, Message: string;
begin
  Result := False;
  if not MailReady then
  begin
    Log('Mail to ' + ToAddress + ' not sent: no [mail] host in the config');
    Exit;
  end;
  From := Config.ReadString('mail', 'from', Config.ReadString('mail', 'user', ''));
  Name := Config.ReadString('mail', 'name', '');
  if Name = '' then
    Name := Setting('name', 'Exedra');
  Sock := nil;
  try
    try
      // As fphttpclient does: made, then connected, which starts the TLS.
      Handler := TSSLSocketHandler.GetDefaultHandler;
      CheckServer(Handler);
      Sock := TInetSocket.Create(Config.ReadString('mail', 'host', ''), Config.ReadInteger('mail', 'port', 465), Handler);
      Sock.ConnectTimeout := 10000;
      Sock.Connect;
      Sock.IOTimeout := 20000;
      Expect(Sock, '', '220');
      Expect(Sock, 'EHLO ' + Config.ReadString('irc', 'name', 'exedra'), '250');
      Expect(Sock, 'AUTH LOGIN', '334');
      Expect(Sock, EncodeStringBase64(Config.ReadString('mail', 'user', '')), '334');
      Expect(Sock, EncodeStringBase64(Config.ReadString('mail', 'password', '')), '235');
      Expect(Sock, 'MAIL FROM:<' + From + '>', '250');
      Expect(Sock, 'RCPT TO:<' + ToAddress + '>', '25');
      Expect(Sock, 'DATA', '354');
      Message := 'From: ' + Name + ' <' + From + '>'#13#10 + 'To: <' + ToAddress + '>'#13#10 + 'Subject: ' + Subject + #13#10 + 'Date: ' +
        FormatDateTime('ddd, dd mmm yyyy hh:nn:ss', NowUTC) + ' +0000'#13#10 + 'Message-ID: <' + RandomHex(12) + '@' + Copy(From, Pos('@', From) + 1, MaxInt) +
        '>'#13#10 + 'MIME-Version: 1.0'#13#10 + 'Content-Type: text/plain; charset=utf-8'#13#10 + 'Content-Transfer-Encoding: 8bit'#13#10 +
        Headers + #13#10 + DotStuffed(Body) + '.';
      Expect(Sock, Message, '250');
      Expect(Sock, 'QUIT', '221');
      Result := True;
    except
      on E: Exception do
        Log('Mail to ' + ToAddress + ' not sent: ' + E.Message);
    end;
  finally
    Sock.Free;
  end;
end;

end.
