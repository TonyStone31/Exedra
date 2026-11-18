unit ChatPrivate;

{ Private conversations between two members.  A conversation is plain
  unless one of them locks it: then it is encrypted in their browsers
  (static/keys.js) and the server stores and relays what it cannot read,
  files included (sealed).  IRC clients (unit ChatIrc) can take part only
  while it is plain.  A plain message is the same JSON object a locked one
  seals: t (text, file or beam), text, and files.

  Beam: a file sent straight from one browser to the other (WebRTC), never
  stored here.  The server only passes the two browsers' connection offers
  between them; the file itself goes peer to peer. }

{$mode objfpc}{$H+}

interface

uses
  fpjson, ChatUsers;

type
  { An unlocked message was sent or written again: its id and its words. }
  TDmTextHook = procedure(DmId: integer; const Text: string);
  { A page of messages is on its way to a reader: more may be put on each;
    Ids is their numbers with commas, read from the database. }
  TDmLoadHook = procedure(List: TJSONArray; const Ids: string);

var
  { What a unit on top adds to unlocked messages (link previews). }
  DmTextHook: TDmTextHook = nil;
  DmLoadHook: TDmLoadHook = nil;

{ The conversation between the two is locked (end-to-end encrypted). }
function DmLocked(UserA, UserB: integer): boolean;
{ A plain message from one member to another; its id. }
function SendPlainDm(FromId, ToId: integer; const Payload: string): integer;
{ Why Me cannot send Other a private message now, or ''. }
function DmRefused(const Me: TMember; Other: integer): string;
{ A message changed (a reaction, a preview that arrived): both sides' open
  conversations show it again. }
procedure DmChanged(DmId: integer);

implementation

uses
  Classes, SysUtils, Variants, sqldb, httpdefs, httproute, ChatDb, SiteSql,
  ChatFiles, ChatMessages, ChatRoles, ChatRooms, ChatMarkup, ChatBell, ChatPush;

function IsBase64(const S: string; MaxLen: integer): boolean;
var
  C: char;
begin
  Result := (S <> '') and (Length(S) <= MaxLen);
  for C in S do
    if not (C in ['A'..'Z', 'a'..'z', '0'..'9', '+', '/', '=']) then
      Exit(False);
end;

function DmLocked(UserA, UserB: integer): boolean;
begin
  Result := IntValue('SELECT COALESCE(MAX(locked), 0) FROM dm_peers WHERE user_id = :a AND other_id = :b', [UserA, UserB]) = 1;
end;

{ GET /api/key?name=  a member's public key, and whether my conversation
  with them is locked }
procedure PublicKey(ARequest: TRequest; AResponse: TResponse);
var
  Answer: TJSONObject;
  Id: integer;
begin
  CheckConnection;
  Answer := nil;
  Id := 0;
  with Query('SELECT name, public_key, avatar, id, key_name FROM users WHERE name = :n', [ARequest.QueryFields.Values['name']]) do
  try
    if not EOF then
    begin
      Answer := TJSONObject.Create(['name', Fields[0].AsString, 'pub', Fields[1].AsString, 'avatar', AvatarUrl(Fields[2].AsString)]);
      Answer.Add('key_name', Fields[4].AsString);
      Id := Fields[3].AsInteger;
    end;
  finally
    Free;
  end;
  if Answer = nil then
    SendText(AResponse, 404, 'No member by that name.')
  else
  begin
    Answer.Add('locked', DmLocked(CurrentMember(ARequest).Id, Id));
    SendJSON(AResponse, Answer);
  end;
end;

{ Each side's list of conversations, newest first, and the bells. }
procedure NoteDm(FromId, ToId, Id: integer; const FromName: string);
begin
  Exec('INSERT INTO dm_peers (user_id, other_id, last_id, last_read_id) VALUES (:u, :o, :l, :l2)' + SqlOnConflict('user_id, other_id',
    'last_id = ' + SqlGreatest('last_id', SqlNew('last_id')) + ', last_read_id = ' + SqlGreatest('last_read_id', SqlNew('last_read_id'))),
    [FromId, ToId, Id, Id]);
  // GREATEST: two messages at once may finish here in either order
  Exec('INSERT INTO dm_peers (user_id, other_id, last_id, last_read_id) VALUES (:u, :o, :l, 0)' + SqlOnConflict('user_id, other_id',
    'last_id = ' + SqlGreatest('last_id', SqlNew('last_id'))),
    [ToId, FromId, Id]);
  RingUser(ToId, BellNote(['t', 'dm', 'from', FromName]));
  RingUser(FromId, BellNote(['t', 'dm', 'from', FromName]));
  NotifyMember(ToId);
end;

{ The words of an unlocked message, out of its JSON. }
function PlainText(const Data: string): string;
var
  Item: TJSONData;
begin
  Result := '';
  try
    Item := GetJSON(Data);
  except
    Exit;
  end;
  try
    if (Item is TJSONObject) and (TJSONObject(Item).Find('text') is TJSONString) then
      Result := TJSONObject(Item).Strings['text'];
  finally
    Item.Free;
  end;
end;

{ An unlocked message's words as a channel message's are shown: Markdown,
  colored code, names and channels linked.  The server can read these; a
  locked message has no such column to fill. }
function PlainHtml(const Data: string): string;
var
  Members, Rooms: TStringList;
  Text: string;
begin
  Result := '';
  Text := PlainText(Data);
  if Trim(Text) = '' then
    Exit;
  Members := TStringList.Create;
  Rooms := TStringList.Create;
  try
    Result := RenderText(Text, @MemberExists, @RoomExists, Members, Rooms);
  finally
    Rooms.Free;
    Members.Free;
  end;
end;

procedure DmChanged(DmId: integer);
begin
  with Query('SELECT d.from_id, d.to_id, a.name, b.name FROM dms d JOIN users a ON a.id = d.from_id JOIN users b ON b.id = d.to_id WHERE d.id = :i', [DmId]) do
  try
    if not EOF then
    begin
      RingUser(Fields[0].AsInteger, BellNote(['t', 'dm', 'from', Fields[3].AsString, 'edited', DmId]));
      RingUser(Fields[1].AsInteger, BellNote(['t', 'dm', 'from', Fields[2].AsString, 'edited', DmId]));
    end;
  finally
    Free;
  end;
end;

function SendPlainDm(FromId, ToId: integer; const Payload: string): integer;
begin
  Exec('INSERT INTO dms (from_id, to_id, iv, data, html) VALUES (:f, :t, '''', :d, :h)', [FromId, ToId, Payload, PlainHtml(Payload)]);
  Result := LastId;
  if Assigned(DmTextHook) then
    DmTextHook(Result, PlainText(Payload));
  NoteDm(FromId, ToId, Result, VarToStr(Value('SELECT name FROM users WHERE id = :u', [FromId])));
end;

function DmRefused(const Me: TMember; Other: integer): string;
begin
  Result := '';
  if not Can(Me, 'private-message') then
    Result := 'Private messages are not open to you here.'
  else if Ignores(Other, Me.Id) then
    Result := 'They are not taking private messages from you.'
  else if IntValue('SELECT COUNT(*) FROM dms WHERE from_id = :u AND created > ' + SqlAgo('10', suSecond), [Me.Id]) >= 10 then
    Result := 'Slow down a little.';
end;

{ A plain message as the page sends it: a JSON object with a known t. }
function PlainPayload(const Data: string): boolean;
var
  Item: TJSONData;
begin
  Result := False;
  if (Data = '') or (Length(Data) > 24000) then
    Exit;
  try
    Item := GetJSON(Data);
  except
    Exit;
  end;
  try
    // the kind as a string, and a text message's text a string too, or a
    // reader's page could not show it (nor what comes after it)
    Result := (Item is TJSONObject) and (TJSONObject(Item).Find('t') is TJSONString) and (Pos('|' + TJSONObject(Item).Strings['t'] + '|', '|text|file|beam|') > 0) and
      ((TJSONObject(Item).Strings['t'] <> 'text') or (TJSONObject(Item).Find('text') is TJSONString));
  finally
    Item.Free;
  end;
end;

{ POST /api/dm/lock  with, on (1 or 0): locks or unlocks the conversation
  for both.  Locking needs both to have keys. }
procedure DmLock(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Other: integer;
  TurnOn: boolean;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Other := MemberId(ARequest.ContentFields.Values['with']);
  TurnOn := ARequest.ContentFields.Values['on'] = '1';
  if Other = 0 then
    SendText(AResponse, 404, 'No member by that name.')
  else if TurnOn and (IntValue('SELECT COUNT(*) FROM users WHERE id IN (:a, :b) AND public_key <> ''''', [Me.Id, Other]) < 2) then
    SendText(AResponse, 409, 'Both of you need a key first: it is made the first time each of you' + ' signs in on the web with a password.')
  else
  begin
    Exec('INSERT INTO dm_peers (user_id, other_id, last_id, last_read_id, locked) VALUES (:u, :o, 0, 0, :l)' + SqlOnConflict('user_id, other_id', 'locked = ' + SqlNew('locked')),
      [Me.Id, Other, Ord(TurnOn)]);
    Exec('INSERT INTO dm_peers (user_id, other_id, last_id, last_read_id, locked) VALUES (:u, :o, 0, 0, :l)' + SqlOnConflict('user_id, other_id', 'locked = ' + SqlNew('locked')),
      [Other, Me.Id, Ord(TurnOn)]);
    RingUser(Other, BellNote(['t', 'dm', 'from', Me.Name]));
    SendText(AResponse, 200, 'ok');
  end;
end;

{ GET /api/dm?with=name&after=id&before=id  the conversation, still
  encrypted: the newest 100 at first, then what came after `after`, or the
  100 before `before` when scrolling back; &id= just that one message, after
  an edit.  Reading it marks it read. }
{ The reactions on a page of messages, put on each as "reactions": which,
  how many, and whether the reader's own is among them. }
procedure AttachReactions(List: TJSONArray; const Ids: string; MeId: integer);
var
  I: integer;
  Item: TJSONObject;
begin
  // Ids is a list of numbers read from the database
  with Query('SELECT dm_id, reaction, COUNT(*), MAX(user_id = :u) FROM dm_reactions WHERE dm_id IN (' + Ids + ') GROUP BY dm_id, reaction ORDER BY dm_id, reaction', [MeId]) do
  try
    while not EOF do
    begin
      for I := 0 to List.Count - 1 do
      begin
        Item := List.Objects[I];
        if Item.Integers['id'] = Fields[0].AsInteger then
          Item.Arrays['reactions'].Add(TJSONObject.Create(['r', Fields[1].AsInteger, 'n', Fields[2].AsInteger, 'mine', Fields[3].AsInteger = 1]));
      end;
      Next;
    end;
  finally
    Free;
  end;
end;

{ Messages between Me and Other with ids between After and Before, 100 at
  most, oldest first: the newest 100 when NewestFirst, else the first 100.
  Words, when given, keeps the unlocked ones that hold it (the server
  cannot look into locked ones). }
function LoadDms(const Me: TMember; Other, After, Before: integer; NewestFirst: boolean; const Words: string; out Newest: integer): TJSONArray;
var
  Item: TJSONObject;
  Ids, Order, Html, Like, SQL: string;
  Files: TJSONObject;
  Cleared: int64;
  I: integer;
  Rows: TSQLQuery;
begin
  Order := '';
  if NewestFirst then
    Order := 'DESC';
  Result := TJSONArray.Create;
  Ids := '';
  Newest := 0;
  Cleared := IntValue('SELECT cleared_id FROM dm_peers WHERE user_id = :u AND other_id = :o', [Me.Id, Other]);
  SQL := 'SELECT d.id, u.name, d.iv, d.data, ' + IsoTime('d.created') + ', u.key_name, d.edited, d.html, d.html IS NULL FROM dms d JOIN users u ON u.id = d.from_id' +
    ' WHERE ((d.from_id = :a AND d.to_id = :b) OR (d.from_id = :c AND d.to_id = :d))' + ' AND d.id > :after AND d.id < :before AND d.id > :cleared';
  if Words <> '' then
  begin
    // the words as they are, not as a pattern
    Like := StringReplace(StringReplace(StringReplace(Words, '\', '\\', [rfReplaceAll]), '%', '\%', [rfReplaceAll]), '_', '\_', [rfReplaceAll]);
    Rows := Query(SQL + ' AND d.iv = '''' AND JSON_VALUE(d.data, ''$.text'') LIKE :q ORDER BY d.id ' + Order + ' LIMIT 100',
      [Me.Id, Other, Other, Me.Id, After, Before, Cleared, '%' + Like + '%']);
  end
  else
    Rows := Query(SQL + ' ORDER BY d.id ' + Order + ' LIMIT 100', [Me.Id, Other, Other, Me.Id, After, Before, Cleared]);
  with Rows do
  try
    while not EOF do
    begin
      Item := TJSONObject.Create(['id', Fields[0].AsInteger, 'from', Fields[1].AsString, 'iv', Fields[2].AsString, 'data', Fields[3].AsString,
        'at', Fields[4].AsString, 'files', TJSONArray.Create, 'reactions', TJSONArray.Create]);
      Item.Add('from_key_name', Fields[5].AsString);
      if Fields[6].AsInteger <> 0 then
        Item.Add('edited', True);
      if Fields[2].AsString = '' then
      begin
        // an unlocked message from before the server shaped them: shaped now, once
        Html := Fields[7].AsString;
        if Fields[8].AsInteger = 1 then
        begin
          Html := PlainHtml(Fields[3].AsString);
          Exec('UPDATE dms SET html = :h WHERE id = :i AND iv = ''''', [Html, Fields[0].AsInteger]);
        end;
        Item.Add('html', Html);
      end;
      if NewestFirst then
        Result.Insert(0, Item)
      else
        Result.Add(Item);
      if Fields[0].AsInteger > Newest then
        Newest := Fields[0].AsInteger;
      if Ids <> '' then
        Ids := Ids + ',';
      Ids := Ids + Fields[0].AsString;
      Next;
    end;
  finally
    Free;
  end;
  if Ids = '' then
    Exit;
  Files := FilesFor(Ids, 'sealed');
  try
    for I := 0 to Result.Count - 1 do
    begin
      Item := Result.Objects[I];
      if Files.Find(Item.Strings['id']) <> nil then
      begin
        Item.Delete('files');
        Item.Add('files', Files.Find(Item.Strings['id']).Clone);
      end;
    end;
  finally
    Files.Free;
  end;
  AttachReactions(Result, Ids, Me.Id);
  if Assigned(DmLoadHook) then
    DmLoadHook(Result, Ids);
end;

procedure DmGet(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Other, Newest, After, Before: integer;
  List: TJSONArray;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Other := MemberId(ARequest.QueryFields.Values['with']);
  After := StrToIntDef(ARequest.QueryFields.Values['after'], 0);
  Before := StrToIntDef(ARequest.QueryFields.Values['before'], 0);
  if StrToIntDef(ARequest.QueryFields.Values['id'], 0) > 0 then
  begin
    After := StrToInt(ARequest.QueryFields.Values['id']) - 1;
    Before := After + 2;
  end;
  if Before = 0 then
    Before := MaxInt;
  // The first look and scrolling back read from the newest end.
  List := LoadDms(Me, Other, After, Before, After = 0, '', Newest);
  if Newest > 0 then
    Exec('UPDATE dm_peers SET last_read_id = ' + SqlGreatest('last_read_id', ':l') + ' WHERE user_id = :u AND other_id = :o',
      [Newest, Me.Id, Other]);
  SendJSON(AResponse, List);
end;

{ GET /api/dm/search?with=name&q=words  the unlocked messages of the
  conversation that hold the words, the newest 100, oldest first.  Locked
  messages are not searched: the server cannot read them. }
procedure DmSearch(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Other, Newest: integer;
  Words: string;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Other := MemberId(ARequest.QueryFields.Values['with']);
  Words := Trim(ARequest.QueryFields.Values['q']);
  if (Other = 0) or (Length(Words) < 2) then
    SendJSON(AResponse, TJSONArray.Create)
  else
    SendJSON(AResponse, LoadDms(Me, Other, 0, MaxInt, True, Words, Newest));
end;

{ POST /api/dm/react  id, r: Me's reaction r on the message put on, or
  taken off when it was there.  For either side of the conversation, locked
  or not: the server keeps who reacted with what, and reads nothing. }
procedure DmReact(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id, R: integer;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Id := StrToIntDef(ARequest.ContentFields.Values['id'], 0);
  R := StrToIntDef(ARequest.ContentFields.Values['r'], -1);
  if (R < 0) or (R > High(Reactions)) then
    SendText(AResponse, 400, 'No such reaction.')
  else if not Can(Me, 'react') or not Can(Me, 'private-message') or (IntValue('SELECT COUNT(*) FROM dms WHERE id = :i AND (from_id = :a OR to_id = :b)',
    [Id, Me.Id, Me.Id]) = 0) then
    SendText(AResponse, 403, 'Reactions are not open to you here.')
  else
  begin
    if IntValue('SELECT COUNT(*) FROM dm_reactions WHERE dm_id = :m AND user_id = :u AND reaction = :r', [Id, Me.Id, R]) > 0 then
      Exec('DELETE FROM dm_reactions WHERE dm_id = :m AND user_id = :u AND reaction = :r', [Id, Me.Id, R])
    else
      Exec(SqlInsertIgnore('dm_reactions', 'dm_id, user_id, reaction', ':m, :u, :r'), [Id, Me.Id, R]);
    DmChanged(Id);
    SendText(AResponse, 200, 'ok');
  end;
end;

{ POST /api/dm/delete  with: this member's copy of the conversation is
  gone.  A message leaves the server once both sides have deleted it. }
{ One message this member sent, taken back from both sides with its files;
  both members are rung with the id so an open conversation drops it. }
procedure DeleteOneDm(const Me: TMember; const IdText: string; AResponse: TResponse);
var
  MsgId, FromId, ToId: integer;
begin
  MsgId := StrToIntDef(IdText, 0);
  FromId := 0;
  ToId := 0;
  with Query('SELECT from_id, to_id FROM dms WHERE id = :i', [MsgId]) do
  try
    if not EOF then
    begin
      FromId := Fields[0].AsInteger;
      ToId := Fields[1].AsInteger;
    end;
  finally
    Free;
  end;
  if FromId = 0 then
    SendText(AResponse, 404, 'That message is already gone.')
  else if FromId <> Me.Id then
    SendText(AResponse, 403, 'Only your own messages can be deleted.')
  else
  begin
    DeleteFilesOf(MsgId, 'sealed');
    DeleteFilesOf(MsgId, 'dmfile');
    Exec('DELETE FROM dms WHERE id = :i', [MsgId]);
    Exec('DELETE FROM dm_reactions WHERE dm_id = :i', [MsgId]);
    // the conversation's newest message may have been the one: both sides'
    // marks move back to what is left, so nothing unread points at nothing
    Exec('UPDATE dm_peers SET last_id = (SELECT COALESCE(MAX(id), 0) FROM dms WHERE (from_id = :a AND to_id = :b) OR (from_id = :c AND to_id = :d))' +
      ' WHERE (user_id = :e AND other_id = :f) OR (user_id = :g AND other_id = :h)', [Me.Id, ToId, ToId, Me.Id, Me.Id, ToId, ToId, Me.Id]);
    Exec('UPDATE dm_peers SET last_read_id = LEAST(last_read_id, last_id)' + ' WHERE (user_id = :a AND other_id = :b) OR (user_id = :c AND other_id = :d)',
      [Me.Id, ToId, ToId, Me.Id]);
    RingUser(Me.Id, BellNote(['t', 'dm', 'from', MemberById(ToId).Name, 'deleted', MsgId]));
    RingUser(ToId, BellNote(['t', 'dm', 'from', Me.Name, 'deleted', MsgId]));
    SendText(AResponse, 200, 'ok');
  end;
end;

procedure DmDelete(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Other, UpTo: integer;
  Ids: TStringList;
  Id: string;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  if ARequest.ContentFields.Values['id'] <> '' then
  begin
    DeleteOneDm(Me, ARequest.ContentFields.Values['id'], AResponse);
    Exit;
  end;
  Other := MemberId(ARequest.ContentFields.Values['with']);
  if Other = 0 then
  begin
    SendText(AResponse, 404, 'No member by that name.');
    Exit;
  end;
  Exec('UPDATE dm_peers SET cleared_id = last_id, last_read_id = last_id WHERE user_id = :u AND other_id = :o',
    [Me.Id, Other]);
  // Both rows are there whenever the two have talked; then the lower mark is what both deleted.
  UpTo := IntValue('SELECT ' + SqlIf('COUNT(*) = 2', 'MIN(cleared_id)', '0') + ' FROM dm_peers' + ' WHERE (user_id = :a AND other_id = :b) OR (user_id = :c AND other_id = :d)',
    [Me.Id, Other, Other, Me.Id]);
  Ids := TStringList.Create;
  try
    with Query('SELECT id FROM dms WHERE ((from_id = :a AND to_id = :b) OR (from_id = :c AND to_id = :d))' + ' AND id <= :m', [Me.Id, Other, Other, Me.Id, UpTo]) do
    try
      while not EOF do
      begin
        Ids.Add(Fields[0].AsString);
        Next;
      end;
    finally
      Free;
    end;
    for Id in Ids do
    begin
      DeleteFilesOf(StrToInt(Id), 'sealed');
      DeleteFilesOf(StrToInt(Id), 'dmfile');
    end;
  finally
    Ids.Free;
  end;
  Exec('DELETE FROM dms WHERE ((from_id = :a AND to_id = :b) OR (from_id = :c AND to_id = :d)) AND id <= :m',
    [Me.Id, Other, Other, Me.Id, UpTo]);
  Exec('DELETE FROM dm_reactions WHERE NOT EXISTS (SELECT 1 FROM dms d WHERE d.id = dm_reactions.dm_id)', []);
  SendText(AResponse, 200, 'ok');
end;

{ POST /api/dm  to, data, files; and iv when the conversation is locked
  (data sealed, files sealed uploads) }
procedure DmPost(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Other, Id: integer;
  Iv, Data: string;
  Locked: boolean;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Other := MemberId(ARequest.ContentFields.Values['to']);
  Iv := ARequest.ContentFields.Values['iv'];
  Data := ARequest.ContentFields.Values['data'];
  Locked := DmLocked(Me.Id, Other);
  if Other = 0 then
    SendText(AResponse, 404, 'No member by that name.')
  else if DmRefused(Me, Other) <> '' then
    SendText(AResponse, 403, DmRefused(Me, Other))
  else if Locked and not (IsBase64(Iv, 32) and IsBase64(Data, 24000)) then
    SendText(AResponse, 409, 'This conversation is locked now. Reload the page.')
  else if not Locked and ((Iv <> '') or not PlainPayload(Data)) then
    SendText(AResponse, 409, 'This conversation is not locked now. Reload the page.')
  else
  begin
    if Locked then
    begin
      Exec('INSERT INTO dms (from_id, to_id, iv, data) VALUES (:f, :t, :i, :d)', [Me.Id, Other, Iv, Data]);
      Id := LastId;
      AttachFiles(Id, 0, Me.Id, ARequest.ContentFields.Values['files'], 'sealed');
      NoteDm(Me.Id, Other, Id, Me.Name);
    end
    else
    begin
      Id := SendPlainDm(Me.Id, Other, Data);
      AttachFiles(Id, 0, Me.Id, ARequest.ContentFields.Values['files'], 'dmfile');
    end;
    SendJSON(AResponse, TJSONObject.Create(['id', Id]));
  end;
end;

{ POST /api/dm/edit  id, data; and iv when the conversation is locked: one
  of the member's own messages, written again.  The page keeps its files
  and kind; the server checks what it can, as for a new message, and rings
  both sides with the id so an open conversation shows the new text. }
procedure DmEdit(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id, Other: integer;
  Iv, Data: string;
  Locked: boolean;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Id := StrToIntDef(ARequest.ContentFields.Values['id'], 0);
  Iv := ARequest.ContentFields.Values['iv'];
  Data := ARequest.ContentFields.Values['data'];
  Other := IntValue('SELECT to_id FROM dms WHERE id = :m AND from_id = :u', [Id, Me.Id]);
  if (Other = 0) or not Can(Me, 'edit-own') or not Can(Me, 'private-message') then
  begin
    SendText(AResponse, 403, 'Only your own messages can be edited.');
    Exit;
  end;
  Locked := DmLocked(Me.Id, Other);
  if Locked and not (IsBase64(Iv, 32) and IsBase64(Data, 24000)) then
    SendText(AResponse, 409, 'This conversation is locked now. Reload the page.')
  else if not Locked and ((Iv <> '') or not PlainPayload(Data)) then
    SendText(AResponse, 409, 'This conversation is not locked now. Reload the page.')
  else
  begin
    if Locked then
    begin
      Exec('UPDATE dms SET iv = :i, data = :d, html = NULL, edited = 1 WHERE id = :m', [Iv, Data, Id]);
      // what it linked to when the server could read it is forgotten
      if Assigned(DmTextHook) then
        DmTextHook(Id, '');
    end
    else
    begin
      Exec('UPDATE dms SET iv = '''', data = :d, html = :h, edited = 1 WHERE id = :m', [Data, PlainHtml(Data), Id]);
      if Assigned(DmTextHook) then
        DmTextHook(Id, PlainText(Data));
    end;
    RingUser(Other, BellNote(['t', 'dm', 'from', Me.Name, 'edited', Id]));
    RingUser(Me.Id, BellNote(['t', 'dm', 'from', MemberById(Other).Name, 'edited', Id]));
    SendText(AResponse, 200, 'ok');
  end;
end;

{ POST /api/dm/typing  to: tells the other member, live, that Me is typing
  to them.  Nothing is stored; their page shows it for a few seconds.  Not
  sent where Me could not send them a message. }
procedure DmTyping(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Other: integer;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Other := MemberId(ARequest.ContentFields.Values['to']);
  if (Other <> 0) and (Other <> Me.Id) and (DmRefused(Me, Other) = '') then
    RingUser(Other, BellNote(['t', 'dmtyping', 'from', Me.Name]));
  SendText(AResponse, 200, 'ok');
end;

{ The member's private conversations, newest first, with unread counts. }
function DmList(const Me: TMember): TJSONArray;
var
  Item: TJSONObject;
  I: integer;
begin
  Result := TJSONArray.Create;
  with Query('SELECT u.name, u.avatar, p.last_id, p.last_read_id, u.id FROM dm_peers p' +
      ' JOIN users u ON u.id = p.other_id WHERE p.user_id = :u AND p.last_id > p.cleared_id' + ' ORDER BY p.last_id DESC LIMIT 40', [Me.Id]) do
  try
    while not EOF do
    begin
      Item := TJSONObject.Create(['name', Fields[0].AsString, 'avatar', AvatarUrl(Fields[1].AsString), 'unread', 0]);
      if Fields[2].AsInteger > Fields[3].AsInteger then
        Item.Integers['unread'] := -Fields[4].AsInteger;
      Item.Add('read', Fields[3].AsInteger);
      Result.Add(Item);
      Next;
    end;
  finally
    Free;
  end;
  // Counted only where something is unread, and only to 100.
  for I := 0 to Result.Count - 1 do
  begin
    Item := Result.Objects[I];
    if Item.Integers['unread'] < 0 then
      Item.Integers['unread'] := IntValue('SELECT COUNT(*) FROM (SELECT 1 FROM dms WHERE from_id = :o' + ' AND to_id = :u AND id > :r LIMIT 100) x',
        [-Item.Integers['unread'], Me.Id, Item.Integers['read']]);
    Item.Delete('read');
  end;
end;

procedure AddDms(ARequest: TRequest; const Me: TMember; Answer: TJSONObject);
begin
  if (Me.Id > 0) and (ARequest.QueryFields.Values['rooms'] = '1') then
    Answer.Add('dms', DmList(Me));
end;

{ Beam }

function BeamAllowed(const Token: string; UserId: integer): boolean;
begin
  Result := IntValue('SELECT COUNT(*) FROM beams WHERE token = :t AND (from_id = :a OR to_id = :b)', [Token, UserId, UserId]) > 0;
end;

{ POST /api/beam  to, offer: the sender's connection offer }
procedure BeamOffer(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Other: integer;
  Token, Offer: string;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Other := MemberId(ARequest.ContentFields.Values['to']);
  Offer := ARequest.ContentFields.Values['offer'];
  if not Can(Me, 'beam') or Ignores(Other, Me.Id) then
  begin
    SendText(AResponse, 403, 'Beams to them are not open to you.');
    Exit;
  end;
  if (Other = 0) or (Offer = '') or (Length(Offer) > 20000) then
  begin
    SendText(AResponse, 400, 'That beam did not come from this site''s page.');
    Exit;
  end;
  Token := RandomHex(12);
  Exec('INSERT INTO beams (token, from_id, to_id, offer) VALUES (:t, :f, :o, :s)', [Token, Me.Id, Other, Offer]);
  SendJSON(AResponse, TJSONObject.Create(['token', Token]));
end;

{ GET /api/beam?token=  the offer and, once given, the answer }
procedure BeamGet(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Token: string;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Token := ARequest.QueryFields.Values['token'];
  if not BeamAllowed(Token, Me.Id) then
  begin
    SendText(AResponse, 404, 'That beam is over.');
    Exit;
  end;
  with Query('SELECT offer, answer FROM beams WHERE token = :t', [Token]) do
  try
    SendJSON(AResponse, TJSONObject.Create(['offer', Fields[0].AsString, 'answer', Fields[1].AsString, 'ice', Setting('ice_servers', 'stun:stun.l.google.com:19302')]));
  finally
    Free;
  end;
end;

{ POST /api/beam/answer  token, answer: the receiver's half }
procedure BeamAnswer(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Token, Answer: string;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Token := ARequest.ContentFields.Values['token'];
  Answer := ARequest.ContentFields.Values['answer'];
  if (IntValue('SELECT COUNT(*) FROM beams WHERE token = :t AND to_id = :u', [Token, Me.Id]) = 0) or (Answer = '') or (Length(Answer) > 20000) then
  begin
    SendText(AResponse, 404, 'That beam is over.');
    Exit;
  end;
  Exec('UPDATE beams SET answer = :a WHERE token = :t', [Answer, Token]);
  SendText(AResponse, 200, 'ok');
end;

procedure ForgetOldBeams;
begin
  Exec('DELETE FROM beams WHERE created < ' + SqlAgo('1', suHour), []);
end;

{ GET /api/ice  the connection helpers browsers use for a beam }
procedure ShowIce(ARequest: TRequest; AResponse: TResponse);
begin
  SendJSON(AResponse, TJSONObject.Create(['ice', Setting('ice_servers', 'stun:stun.l.google.com:19302')]));
end;

{ Unlocked messages keep the HTML made for them. Once for each
  DM_CODE_COLORS, at startup, those with a code block lose it, and are
  shaped again when next read: a language colored since then gets its
  colors. }
procedure ColorOldDmCode;
const
  DM_CODE_COLORS = '4';
begin
  if Setting('dm_code_colors', '') = DM_CODE_COLORS then
    Exit;
  Exec('UPDATE dms SET html = NULL WHERE iv = '''' AND data LIKE ''%```%''', []);
  SaveSetting('dm_code_colors', DM_CODE_COLORS);
end;

initialization
  // Private messages, encrypted in the browsers.
  RegisterTable('CREATE TABLE IF NOT EXISTS dms (' + ' id INT AUTO_INCREMENT PRIMARY KEY,' + ' from_id INT NOT NULL, to_id INT NOT NULL,' +
    ' iv VARCHAR(32) NOT NULL, data MEDIUMTEXT NOT NULL,' + ' created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,' + ' INDEX (from_id, to_id), INDEX (to_id))');
  // the sender's latest, for the pace check in DmRefused
  RegisterUpgrade('dms-from-created', 'ALTER TABLE dms ADD INDEX dms_from_created (from_id, created)');
  // set when the sender has written a message again (POST /api/dm/edit)
  RegisterUpgrade('dms-edited', 'ALTER TABLE dms ADD COLUMN edited TINYINT NOT NULL DEFAULT 0');
  // One row for each side of each conversation: its newest message and the
  // last one that side read.
  RegisterTable('CREATE TABLE IF NOT EXISTS dm_peers (' + ' user_id INT NOT NULL, other_id INT NOT NULL, last_id INT NOT NULL, last_read_id INT NOT NULL,' +
    ' PRIMARY KEY (user_id, other_id), INDEX (user_id, last_id))');
  RegisterTable('CREATE TABLE IF NOT EXISTS beams (' + ' token CHAR(24) PRIMARY KEY, from_id INT NOT NULL, to_id INT NOT NULL,' +
    ' offer MEDIUMTEXT NOT NULL, answer MEDIUMTEXT NULL,' + ' created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)');
  // Conversations before locking existed were all encrypted.
  RegisterUpgrade('dm-locked', 'ALTER TABLE dm_peers ADD COLUMN locked TINYINT NOT NULL DEFAULT 0');
  RegisterUpgrade('dm-locked-before', 'UPDATE dm_peers SET locked = 1');
  // Each side's copy ends at cleared_id; older messages are gone for that side.
  RegisterUpgrade('dm-cleared', 'ALTER TABLE dm_peers ADD COLUMN cleared_id INT NOT NULL DEFAULT 0');
  // An unlocked message as the server shows it, made when it is sent or
  // written again (and on first reading, for those from before). NULL for
  // a locked one, which the server cannot read.
  RegisterUpgrade('dms-html', 'ALTER TABLE dms ADD COLUMN html MEDIUMTEXT NULL');
  RegisterTable('CREATE TABLE IF NOT EXISTS dm_reactions (' + ' dm_id INT NOT NULL, user_id INT NOT NULL, reaction TINYINT NOT NULL,' +
    ' PRIMARY KEY (dm_id, user_id, reaction))');
  RegisterStartup(@ColorOldDmCode);
  RegisterSyncHook(@AddDms);
  RegisterChore(@ForgetOldBeams, 30);
  RegisterPermission('private-message', 'Send private messages', 'member');
  RegisterPermission('beam', 'Beam files to another member', 'member');
  HTTPRouter.RegisterRoute('/api/key', rmGet, @PublicKey);
  HTTPRouter.RegisterRoute('/api/dm', rmGet, @DmGet);
  HTTPRouter.RegisterRoute('/api/dm', rmPost, @DmPost);
  HTTPRouter.RegisterRoute('/api/dm/lock', rmPost, @DmLock);
  HTTPRouter.RegisterRoute('/api/dm/delete', rmPost, @DmDelete);
  HTTPRouter.RegisterRoute('/api/dm/typing', rmPost, @DmTyping);
  HTTPRouter.RegisterRoute('/api/dm/edit', rmPost, @DmEdit);
  HTTPRouter.RegisterRoute('/api/dm/react', rmPost, @DmReact);
  HTTPRouter.RegisterRoute('/api/dm/search', rmGet, @DmSearch);
  HTTPRouter.RegisterRoute('/api/beam', rmPost, @BeamOffer);
  HTTPRouter.RegisterRoute('/api/beam', rmGet, @BeamGet);
  HTTPRouter.RegisterRoute('/api/beam/answer', rmPost, @BeamAnswer);
  HTTPRouter.RegisterRoute('/api/ice', rmGet, @ShowIce);
end.
