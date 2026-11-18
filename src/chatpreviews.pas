unit ChatPreviews;

{ A line about the first web link in a message: its title, a line of
  description, a picture and the site's name, fetched once the message is
  posted or edited and kept by address for a week.  Clients fold it to one
  line; the picture's address goes out, never the picture, so a reader's
  browser asks for it only when they open the line.

  The fetch runs on a thread of its own with a connection of its own, as
  pushes do: http or https to a public host on the usual ports, up to three
  redirects each checked the same way, the first FETCH_CAP bytes of a
  text/html answer and nothing else.  When it is done the message gets a
  new revision, so pages showing it ask again.  The admin setting
  link_previews turns the whole thing off. }

{$mode objfpc}{$H+}

interface

{ Only a public web host on the usual ports, without looking the name up. }
function PublicWebAddress(const Url: string): boolean;
{ The same, and every address the name gives is public: for anything that
  fetches an address a stranger chose. }
function ResolvesPublic(const Url: string): boolean;

implementation

uses
  Classes, SysUtils, StrUtils, Variants, fpjson, fphttpclient, opensslsockets, netdb, sockets, URIParser, sha1, ChatDb, SiteSql, ChatMessages, ChatPrivate, ChatGuard, ChatTls;

const
  PREVIEW_DAYS = 7;
  FETCH_CAP = 262144;
  USER_AGENT = 'Mozilla/5.0 (compatible; Exedra/1; link preview)';

type
  TPreviewJob = class(TThread)
  private
    MessageId: integer;
    Url, Hash: string;
    Got: TMemoryStream;
    procedure Receiving(Sender: TObject; const ContentLength, CurrentPos: int64);
    procedure Redirecting(Sender: TObject; const ASrc: string; var ADest: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AMessageId: integer; const AUrl, AHash: string);
  end;

  { ------------------------------------------------------------ the address }

{ A private, loopback, shared or multicast IPv4 address, by its first two numbers. }
function PrivateV4(A, B: integer): boolean;
begin
  Result := (A < 1) or (A = 10) or (A = 127) or ((A = 169) and (B = 254)) or ((A = 192) and (B = 168)) or ((A = 172) and (B >= 16) and (B <= 31)) or
    ((A = 100) and (B >= 64) and (B <= 127)) or (A >= 224);
end;

{ Only a public web host on the usual ports.  A name without a dot, the
  loopback and private ranges, and IPv6 literals are refused: the server
  must not be talked into reading its own network. }
function PublicWebAddress(const Url: string): boolean;
var
  U: TURI;
  Host: string;
  A, B: integer;
  Parts: TStringArray;
begin
  Result := False;
  U := ParseURI(Url);
  if (U.Protocol <> 'http') and (U.Protocol <> 'https') then
    Exit;
  // plain comparisons: a set stops at 255
  if (U.Port <> 0) and (U.Port <> 80) and (U.Port <> 443) then
    Exit;
  Host := LowerCase(U.Host);
  if (Host = '') or (Pos('.', Host) = 0) or (Pos(':', Host) > 0) or (Host = 'localhost') then
    Exit;
  if Host.EndsWith('.local') or Host.EndsWith('.localhost') or Host.EndsWith('.internal') or Host.EndsWith('.lan') then
    Exit;
  if Host[1] in ['0'..'9'] then
  begin
    Parts := Host.Split(['.']);
    if Length(Parts) <> 4 then
      Exit;
    A := StrToIntDef(Parts[0], -1);
    B := StrToIntDef(Parts[1], -1);
    if PrivateV4(A, B) then
      Exit;
  end;
  Result := True;
end;

{ As PublicWebAddress, and the name looked up: a public name may point
  into the house's network, and every address it gives must be public.
  Asked in the job, before the fetch and at each redirect, so posting is
  not kept waiting. }
function ResolvesPublic(const Url: string): boolean;
var
  Addresses: array[0..15] of THostAddr;
  Host: string;
  I, N: integer;
begin
  Result := PublicWebAddress(Url);
  if not Result then
    Exit;
  Host := LowerCase(ParseURI(Url).Host);
  if Host[1] in ['0'..'9'] then
    Exit;
  N := ResolveName(Host, Addresses);
  if N <= 0 then
    Exit(False);
  if N > Length(Addresses) then
    N := Length(Addresses);
  for I := 0 to N - 1 do
    if PrivateV4(Addresses[I].s_bytes[1], Addresses[I].s_bytes[2]) then
      Exit(False);
end;

{ The first web link in a message, outside its code, trailing punctuation
  taken off; '' when there is none. }
function FirstLink(const Body: string): string;
var
  Text: string;
  I, J, Start: integer;
  InFence, InTick: boolean;
begin
  Result := '';
  // code stays code: a fenced block or a backticked span is skipped whole
  Text := '';
  InFence := False;
  InTick := False;
  I := 1;
  while I <= Length(Body) do
  begin
    if (Copy(Body, I, 3) = '```') then
    begin
      InFence := not InFence;
      Inc(I, 3);
      Text := Text + ' ';
      Continue;
    end;
    if (Body[I] = '`') and not InFence then
    begin
      InTick := not InTick;
      Text := Text + ' ';
    end
    else if InFence or InTick then
      Text := Text + ' '
    else
      Text := Text + Body[I];
    Inc(I);
  end;
  Start := Pos('https://', Text);
  J := Pos('http://', Text);
  if (J > 0) and ((Start = 0) or (J < Start)) then
    Start := J;
  if Start = 0 then
    Exit;
  // a link written in Markdown has its address in parentheses
  J := Start;
  while (J <= Length(Text)) and not (Text[J] in [' ', #9, #10, #13, '<', '>', '"', '''', ')', ']', '}']) do
    Inc(J);
  Result := Copy(Text, Start, J - Start);
  while (Result <> '') and (Result[Length(Result)] in ['.', ',', ';', ':', '!', '?']) do
    SetLength(Result, Length(Result) - 1);
  if (Length(Result) > 700) or (Length(Result) < 11) then
    Result := '';
end;

{ ------------------------------------------------------------- the page }

function Utf8Of(Code: cardinal): string;
begin
  if Code < $80 then
    Result := Chr(Code)
  else if Code < $800 then
    Result := Chr($C0 or (Code shr 6)) + Chr($80 or (Code and $3F))
  else if Code < $10000 then
    Result := Chr($E0 or (Code shr 12)) + Chr($80 or ((Code shr 6) and $3F)) + Chr($80 or (Code and $3F))
  else if Code <= $10FFFF then
    Result := Chr($F0 or (Code shr 18)) + Chr($80 or ((Code shr 12) and $3F)) + Chr($80 or ((Code shr 6) and $3F)) + Chr($80 or (Code and $3F))
  else
    Result := '';
end;

{ The named and numbered entities a title or description carries, and the
  whitespace of a page collapsed to single spaces. }
function CleanText(const S: string; MaxLen: integer): string;
var
  I, J: integer;
  Name: string;
  Code: cardinal;
  Ok: boolean;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '&' then
    begin
      J := I + 1;
      while (J <= Length(S)) and (J - I < 10) and (S[J] <> ';') and (S[J] <> ' ') and (S[J] <> '&') do
        Inc(J);
      if (J <= Length(S)) and (S[J] = ';') then
      begin
        Name := LowerCase(Copy(S, I + 1, J - I - 1));
        Ok := True;
        if Name = 'amp' then
          Result := Result + '&'
        else if Name = 'lt' then
          Result := Result + '<'
        else if Name = 'gt' then
          Result := Result + '>'
        else if Name = 'quot' then
          Result := Result + '"'
        else if (Name = 'apos') or (Name = '#39') then
          Result := Result + ''''
        else if Name = 'nbsp' then
          Result := Result + ' '
        else if (Name = 'ndash') then
          Result := Result + Utf8Of($2013)
        else if (Name = 'mdash') then
          Result := Result + Utf8Of($2014)
        else if (Name = 'hellip') then
          Result := Result + Utf8Of($2026)
        else if (Length(Name) > 1) and (Name[1] = '#') then
        begin
          if Name[2] = 'x' then
            Code := StrToIntDef('$' + Copy(Name, 3, MaxInt), 0)
          else
            Code := StrToIntDef(Copy(Name, 2, MaxInt), 0);
          if Code >= 32 then
            Result := Result + Utf8Of(Code)
          else
            Ok := False;
        end
        else
          Ok := False;
        if Ok then
        begin
          I := J + 1;
          Continue;
        end;
      end;
    end;
    if S[I] in [#9, #10, #13] then
      Result := Result + ' '
    else
      Result := Result + S[I];
    Inc(I);
  end;
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  Result := Trim(Result);
  if Length(Result) > MaxLen then
  begin
    SetLength(Result, MaxLen);
    // not in the middle of a UTF-8 character
    while (Result <> '') and (Ord(Result[Length(Result)]) and $C0 = $80) do
      SetLength(Result, Length(Result) - 1);
    if Result <> '' then
      SetLength(Result, Length(Result) - 1);
    Result := Trim(Result) + Utf8Of($2026);
  end;
end;

{ the value of one attribute of a tag's text, '' when it is not there }
function AttrOf(const Tag, Attr: string): string;
var
  Low: string;
  P, E: integer;
  Q: char;
begin
  Result := '';
  Low := LowerCase(Tag);
  P := Pos(' ' + Attr + '=', Low);
  if P = 0 then
    P := Pos(#10 + Attr + '=', Low);
  if P = 0 then
    Exit;
  P := P + Length(Attr) + 2;
  while (P <= Length(Tag)) and (Tag[P] = ' ') do
    Inc(P);
  if P > Length(Tag) then
    Exit;
  if Tag[P] in ['"', ''''] then
  begin
    Q := Tag[P];
    Inc(P);
    E := P;
    while (E <= Length(Tag)) and (Tag[E] <> Q) do
      Inc(E);
  end
  else
  begin
    E := P;
    while (E <= Length(Tag)) and not (Tag[E] in [' ', '>', '/', #9, #10, #13]) do
      Inc(E);
  end;
  Result := Copy(Tag, P, E - P);
end;

{ What the page says about itself: Open Graph first, the plain tags after. }
procedure ReadPage(const Page, PageUrl: string; out Title, Descr, Image, Site: string);
var
  Low, Tag, Key, Content, OgTitle, OgDescr, MetaDescr: string;
  P, E: integer;
  U: TURI;
begin
  Title := '';
  Descr := '';
  Image := '';
  Site := '';
  OgTitle := '';
  OgDescr := '';
  MetaDescr := '';
  Low := LowerCase(Page);
  P := Pos('<title', Low);
  if P > 0 then
  begin
    P := PosEx('>', Low, P);
    E := PosEx('</title', Low, P + 1);
    if (P > 0) and (E > P) then
      Title := CleanText(Copy(Page, P + 1, E - P - 1), 200);
  end;
  P := Pos('<meta', Low);
  while P > 0 do
  begin
    E := PosEx('>', Low, P);
    if E = 0 then
      Break;
    Tag := Copy(Page, P, E - P + 1);
    Key := LowerCase(AttrOf(Tag, 'property'));
    if Key = '' then
      Key := LowerCase(AttrOf(Tag, 'name'));
    Content := AttrOf(Tag, 'content');
    if Content <> '' then
    begin
      if (Key = 'og:title') or (Key = 'twitter:title') then
        OgTitle := CleanText(Content, 200)
      else if (Key = 'og:description') or (Key = 'twitter:description') then
        OgDescr := CleanText(Content, 400)
      else if Key = 'description' then
        MetaDescr := CleanText(Content, 400)
      else if ((Key = 'og:image') or (Key = 'og:image:url') or (Key = 'twitter:image')) and (Image = '') then
        Image := Trim(Content)
      else if Key = 'og:site_name' then
        Site := CleanText(Content, 80);
    end;
    P := PosEx('<meta', Low, E);
  end;
  if OgTitle <> '' then
    Title := OgTitle;
  if OgDescr <> '' then
    Descr := OgDescr
  else
    Descr := MetaDescr;
  U := ParseURI(PageUrl);
  if Site = '' then
    Site := U.Host;
  // the picture's address made absolute, and only a web one is kept
  if Image.StartsWith('//') then
    Image := U.Protocol + ':' + Image
  else if Image.StartsWith('/') then
    Image := U.Protocol + '://' + U.Host + Image
  else if not (Image.StartsWith('http://') or Image.StartsWith('https://')) then
    Image := '';
  if (Length(Image) > 700) or (Pos('"', Image) > 0) or (Pos(' ', Image) > 0) then
    Image := '';
  if Length(Title) < 2 then
    Title := '';
end;

{ -------------------------------------------------------------- the job }

constructor TPreviewJob.Create(AMessageId: integer; const AUrl, AHash: string);
begin
  MessageId := AMessageId;
  Url := AUrl;
  Hash := AHash;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TPreviewJob.Receiving(Sender: TObject; const ContentLength, CurrentPos: int64);
begin
  // the head is at the front; past the cap the rest is not wanted
  if CurrentPos > FETCH_CAP then
    Abort;
end;

procedure TPreviewJob.Redirecting(Sender: TObject; const ASrc: string; var ADest: string);
begin
  if not ResolvesPublic(ADest) then
    ADest := '';
end;

procedure TPreviewJob.Execute;
var
  Client: TFPHTTPClient;
  Kind, Page, Title, Descr, Image, Site: string;
  Fine: boolean;
begin
  Got := TMemoryStream.Create;
  Client := TFPHTTPClient.Create(nil);
  CheckServers(Client);
  try
    try
      Fine := False;
      Title := '';
      Descr := '';
      Image := '';
      Site := '';
      Client.ConnectTimeout := 5000;
      Client.IOTimeout := 8000;
      Client.AllowRedirect := True;
      Client.MaxRedirects := 3;
      Client.AddHeader('User-Agent', USER_AGENT);
      Client.AddHeader('Accept', 'text/html');
      Client.AddHeader('Accept-Language', 'en');
      Client.OnDataReceived := @Receiving;
      Client.OnRedirect := @Redirecting;
      try
        if ResolvesPublic(Url) then
          Client.Get(Url, Got)
        else
          Log('Preview of ' + Copy(Url, 1, 80) + ': not a public address');
      except
        // the cap, or a page that would not come; what did come is read
        on EAbort do ;
        on E: Exception do
          Log('Preview of ' + Copy(Url, 1, 80) + ': ' + E.Message);
      end;
      Kind := LowerCase(Client.ResponseHeaders.Values['Content-Type']);
      if (Client.ResponseStatusCode = 200) and ((Pos('text/html', Kind) > 0) or (Pos('application/xhtml', Kind) > 0)) and (Got.Size > 0) then
      begin
        SetLength(Page, Got.Size);
        Got.Position := 0;
        Got.ReadBuffer(Page[1], Got.Size);
        ReadPage(Page, Url, Title, Descr, Image, Site);
        Fine := Title <> '';
      end;
      if Restoring then
        Exit;
      CheckConnection;
      try
        Exec('UPDATE previews SET title = :t, descr = :d, image = :i, site = :s, ok = :o, fetched = NOW() WHERE url_hash = :h',
          [Title, Descr, Image, Site, Ord(Fine), Hash]);
        // a private message's job carries its number below zero
        if Fine and (MessageId < 0) then
          DmChanged(-MessageId)
        else if Fine then
          Touch(MessageId);
      finally
        DoneConnection;
      end;
    except
      on E: Exception do
        Log('Preview: ' + E.Message);
    end;
  finally
    Client.Free;
    Got.Free;
  end;
end;

{ ------------------------------------------------------------- the hooks }

{ A message posted or edited: its first link noted, fetched when it is new
  to the site or a week old. }
procedure NoteLinks(MessageId: integer; const Body: string);
var
  Url, Hash: string;
  Fresh: boolean;
begin
  Url := '';
  if SettingInt('link_previews', 1) = 1 then
    Url := FirstLink(Body);
  if (Url = '') or not PublicWebAddress(Url) then
  begin
    Exec('DELETE FROM message_previews WHERE message_id = :m', [MessageId]);
    Exit;
  end;
  Hash := SHA1Print(SHA1String(Url));
  Exec('INSERT INTO message_previews (message_id, url_hash) VALUES (:m, :h)' + SqlOnConflict('message_id', 'url_hash = ' + SqlNew('url_hash')), [MessageId, Hash]);
  Fresh := IntValue('SELECT COUNT(*) FROM previews WHERE url_hash = :h AND fetched > ' + SqlAgo(IntToStr(PREVIEW_DAYS), suDay), [Hash]) > 0;
  if Fresh then
    Exit;
  Exec('INSERT INTO previews (url_hash, url, title, descr, image, site, ok, fetched) VALUES (:h, :u, '''', '''', '''', '''', 0, NOW())' +
    SqlOnConflict('url_hash', 'url = ' + SqlNew('url') + ', ok = 0, fetched = NOW()'), [Hash, Url]);
  // a CGI program has no threads (no cthreads in its build): no previews there
  {$ifndef CGI}
  TPreviewJob.Create(MessageId, Url, Hash);
  {$endif}
end;

{ The previews of a page of messages, put on each as "preview". }
procedure AttachPreviews(List: TJSONArray; const Ids: string);
var
  I: integer;
  Item: TJSONObject;
begin
  // Ids is a list of numbers the caller read from the database
  with Query('SELECT mp.message_id, p.url, p.title, p.descr, p.image, p.site FROM message_previews mp' +
      ' JOIN previews p ON p.url_hash = mp.url_hash WHERE p.ok = 1 AND mp.message_id IN (' + Ids + ')', []) do
  try
    while not EOF do
    begin
      for I := 0 to List.Count - 1 do
      begin
        Item := List.Objects[I];
        if Item.Integers['id'] = Fields[0].AsInteger then
          Item.Add('preview', TJSONObject.Create(['url', Fields[1].AsString, 'title', Fields[2].AsString, 'description', Fields[3].AsString,
            'image', Fields[4].AsString, 'site', Fields[5].AsString]));
      end;
      Next;
    end;
  finally
    Free;
  end;
end;

{ An unlocked private message sent or written again: its first link noted
  and fetched like a channel message's.  The job is given the message's
  number below zero, so it knows whom to tell when the page has come. }
procedure NoteDmLinks(DmId: integer; const Text: string);
var
  Url, Hash: string;
begin
  Url := '';
  if SettingInt('link_previews', 1) = 1 then
    Url := FirstLink(Text);
  if (Url = '') or not PublicWebAddress(Url) then
  begin
    Exec('DELETE FROM dm_previews WHERE dm_id = :m', [DmId]);
    Exit;
  end;
  Hash := SHA1Print(SHA1String(Url));
  Exec('INSERT INTO dm_previews (dm_id, url_hash) VALUES (:m, :h)' + SqlOnConflict('dm_id', 'url_hash = ' + SqlNew('url_hash')), [DmId, Hash]);
  if IntValue('SELECT COUNT(*) FROM previews WHERE url_hash = :h AND fetched > ' + SqlAgo(IntToStr(PREVIEW_DAYS), suDay), [Hash]) > 0 then
    Exit;
  Exec('INSERT INTO previews (url_hash, url, title, descr, image, site, ok, fetched) VALUES (:h, :u, '''', '''', '''', '''', 0, NOW())' +
    SqlOnConflict('url_hash', 'url = ' + SqlNew('url') + ', ok = 0, fetched = NOW()'), [Hash, Url]);
  {$ifndef CGI}
  TPreviewJob.Create(-DmId, Url, Hash);
  {$endif}
end;

{ The previews of a page of private messages, put on each as "preview". }
procedure AttachDmPreviews(List: TJSONArray; const Ids: string);
var
  I: integer;
  Item: TJSONObject;
begin
  // Ids is a list of numbers the caller read from the database
  with Query('SELECT mp.dm_id, p.url, p.title, p.descr, p.image, p.site FROM dm_previews mp' +
      ' JOIN previews p ON p.url_hash = mp.url_hash WHERE p.ok = 1 AND mp.dm_id IN (' + Ids + ')', []) do
  try
    while not EOF do
    begin
      for I := 0 to List.Count - 1 do
      begin
        Item := List.Objects[I];
        // a message locked since has no preview to show
        if (Item.Integers['id'] = Fields[0].AsInteger) and (Item.Strings['iv'] = '') then
          Item.Add('preview', TJSONObject.Create(['url', Fields[1].AsString, 'title', Fields[2].AsString, 'description', Fields[3].AsString,
            'image', Fields[4].AsString, 'site', Fields[5].AsString]));
      end;
      Next;
    end;
  finally
    Free;
  end;
end;

procedure ForgetOldPreviews;
begin
  Exec('DELETE FROM dm_previews WHERE NOT EXISTS (SELECT 1 FROM dms d WHERE d.id = dm_previews.dm_id)', []);
  Exec('DELETE FROM previews WHERE fetched < ' + SqlAgo('60', suDay), []);
end;

initialization
  RegisterTable('CREATE TABLE IF NOT EXISTS previews (' + ' url_hash CHAR(40) PRIMARY KEY, url VARCHAR(700) NOT NULL,' +
    ' title VARCHAR(300) NOT NULL DEFAULT '''', descr VARCHAR(600) NOT NULL DEFAULT '''', image VARCHAR(700) NOT NULL DEFAULT '''',' +
    ' site VARCHAR(120) NOT NULL DEFAULT '''', ok TINYINT NOT NULL DEFAULT 0, fetched DATETIME NULL, INDEX (fetched))');
  RegisterTable('CREATE TABLE IF NOT EXISTS message_previews (' + ' message_id INT PRIMARY KEY, url_hash CHAR(40) NOT NULL, INDEX (url_hash))');
  RegisterSetting('link_previews', 'Show a title and picture for the first link in a message', '1', 'yesno');
  RegisterTable('CREATE TABLE IF NOT EXISTS dm_previews (' + ' dm_id INT PRIMARY KEY, url_hash CHAR(40) NOT NULL, INDEX (url_hash))');
  DmTextHook := @NoteDmLinks;
  DmLoadHook := @AttachDmPreviews;
  RegisterMessageHook(@NoteLinks);
  RegisterLoadHook(@AttachPreviews);
  RegisterChore(@ForgetOldPreviews, 24 * 60);
end.
