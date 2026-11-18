unit ChatMessages;

{ Messages: posting, editing, deleting, threads, reactions, pins, search,
  and the one request pages repeat to stay current (/api/sync).

  Every message has a revision, the time it last changed, so a page asks
  for everything newer than what it has: new messages, edits, deletions and
  reactions all come the same way.  A message belongs to the room it was
  said in and, while the cross_post setting is on, is also listed in
  every public room it names as #room.
  Replies stay in their thread; the message they answer carries the count.

  Built so a site can grow large: a room's messages are read through
  message_rooms by (room, id) or (room, revision), never by scanning, and
  nothing is written per follower when someone posts.  A page with a live
  connection (ChatBell) syncs when it hears a ring; one without asks every
  few seconds.

  Other units add slash commands (RegisterCommand) and add to the sync
  answer (RegisterSyncHook). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, httpdefs, ChatUsers, ChatRooms;

const
  Reactions: array[0..5] of string = ('👍', '❤️', '😂', '🎉', '🤔', '👎');

type
  TCommandResult = record
    Post: string;   // posted as the member's message when not empty
    Info: string;   // shown to the member only
    Go: string;     // a page to open, such as /p/lobby
  end;
  TCommandFunc = function(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
  TSyncHook = procedure(ARequest: TRequest; const Me: TMember; Answer: TJSONObject);

  { after a message is posted or edited, with what it says; and after a
    page of messages is loaded, with the list and its ids as a list of
    numbers for an IN - what units on top add to messages (link previews) }
  TMessageHook = procedure(MessageId: integer; const Body: string);
  TLoadHook = procedure(List: TJSONArray; const Ids: string);

procedure RegisterCommand(const Name, Usage: string; Func: TCommandFunc);
procedure RegisterSyncHook(Hook: TSyncHook);
procedure RegisterMessageHook(Hook: TMessageHook);
procedure RegisterLoadHook(Hook: TLoadHook);
{ A message changed: a new revision, and the pages showing it rung. }
procedure Touch(MessageId: integer; Fresh: boolean = False);
function AddMessage(const Room: TRoom; Parent, UserId: integer; const Author, Body, Files: string): integer;
{ Messages as JSON.  Where follows the joins and the WHERE of the query. }
function LoadMessages(const Where: string; const Values: array of variant; const Me: TMember): TJSONArray;
{ The week's messages with the most reactions. }
function BestOfWeek(const Me: TMember): TJSONArray;
function CommandResult(const Post, Info: string; const Go: string = ''): TCommandResult;
function Say(const Me: TMember; Room: TRoom; Parent: integer; Body: string; const Files: string; out Info, Go: string; out Status: integer): integer;

implementation

uses
  StrUtils, Variants, httproute, ChatDb, SiteSql, ChatMarkup, ChatFiles, ChatRoles, ChatBell, ChatPush;

const
  MaxBody = 8000;

type
  TCommand = record
    Name, Usage: string;
    Func: TCommandFunc;
  end;

var
  Commands: array of TCommand;
  SyncHooks: array of TSyncHook;

procedure RegisterCommand(const Name, Usage: string; Func: TCommandFunc);
begin
  SetLength(Commands, Length(Commands) + 1);
  Commands[High(Commands)].Name := Name;
  Commands[High(Commands)].Usage := Usage;
  Commands[High(Commands)].Func := Func;
end;

procedure RegisterSyncHook(Hook: TSyncHook);
begin
  SetLength(SyncHooks, Length(SyncHooks) + 1);
  SyncHooks[High(SyncHooks)] := Hook;
end;

var
  MessageHooks: array of TMessageHook;
  LoadHooks: array of TLoadHook;

procedure RegisterMessageHook(Hook: TMessageHook);
begin
  SetLength(MessageHooks, Length(MessageHooks) + 1);
  MessageHooks[High(MessageHooks)] := Hook;
end;

procedure RegisterLoadHook(Hook: TLoadHook);
begin
  SetLength(LoadHooks, Length(LoadHooks) + 1);
  LoadHooks[High(LoadHooks)] := Hook;
end;

procedure RunMessageHooks(MessageId: integer; const Body: string);
var
  H: TMessageHook;
begin
  for H in MessageHooks do
    H(MessageId, Body);
end;

function CommandResult(const Post, Info: string; const Go: string): TCommandResult;
begin
  Result.Post := Post;
  Result.Info := Info;
  Result.Go := Go;
end;

{ Reading }

function MessageColumns: string;
begin
  Result := 'SELECT m.id, r.slug, m.parent_id, m.user_id, COALESCE(u.name, m.author), u.avatar, u.roles,' + ' m.body, m.html, ' +
    IsoTime('m.created') + ', m.edited, m.deleted, m.pinned, m.reply_count, ' + IsoTime('m.last_reply') + ', m.rev' +
    ' FROM messages m JOIN rooms r ON r.id = m.room_id LEFT JOIN users u ON u.id = m.user_id ';
end;

function FindById(List: TJSONArray; Id: integer): TJSONObject;
var
  I: integer;
begin
  Result := nil;
  for I := 0 to List.Count - 1 do
    if List.Objects[I].Integers['id'] = Id then
      Exit(List.Objects[I]);
end;

function LoadMessages(const Where: string; const Values: array of variant; const Me: TMember): TJSONArray;
var
  Item: TJSONObject;
  Ids, Ignored: string;
  Deleted: boolean;
  Files: TJSONObject;
  I: integer;
begin
  Result := TJSONArray.Create;
  Ids := '';
  Ignored := ',' + IgnoredIds(Me.Id) + ',';
  with Query(MessageColumns + Where, Values) do
  try
    while not EOF do
    begin
      Deleted := Fields[11].AsInteger = 1;
      Item := TJSONObject.Create(['id', Fields[0].AsInteger, 'room', Fields[1].AsString, 'parent', Fields[2].AsInteger, 'uid',
        Fields[3].AsInteger, 'name', Fields[4].AsString, 'avatar', AvatarUrl(Fields[5].AsString), 'badge', Badge(Fields[6].AsString),
        'at', Fields[9].AsString, 'edited', Fields[10].AsInteger = 1, 'deleted', Deleted, 'pinned', Fields[12].AsInteger = 1, 'replies',
        Fields[13].AsInteger, 'last_reply', Fields[14].AsString, 'rev', Fields[15].AsLargeInt, 'mentions_me', False, 'ignored', Pos(',' + Fields[3].AsString + ',', Ignored) > 0]);
      if Deleted then
      begin
        Item.Add('body', '');
        Item.Add('html', '');
      end
      else
      begin
        Item.Add('body', Fields[7].AsString);
        Item.Add('html', Fields[8].AsString);
      end;
      Item.Add('reactions', TJSONArray.Create);
      Item.Add('files', TJSONArray.Create);
      Result.Add(Item);
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

  // Ids is a list of numbers read from the database above.
  with Query('SELECT message_id, reaction, COUNT(*), SUM(user_id = :u) FROM reactions' + ' WHERE message_id IN (' + Ids +
      ') GROUP BY message_id, reaction ORDER BY reaction', [Me.Id]) do
  try
    while not EOF do
    begin
      Item := FindById(Result, Fields[0].AsInteger);
      Item.Arrays['reactions'].Add(TJSONObject.Create(['r', Fields[1].AsInteger, 'n', Fields[2].AsInteger, 'mine', Fields[3].AsInteger > 0]));
      Next;
    end;
  finally
    Free;
  end;

  if Me.Id > 0 then
    with Query('SELECT message_id FROM mentions WHERE user_id = :u AND message_id IN (' + Ids + ')', [Me.Id]) do
    try
      while not EOF do
      begin
        FindById(Result, Fields[0].AsInteger).Booleans['mentions_me'] := True;
        Next;
      end;
    finally
      Free;
    end;

  Files := FilesFor(Ids, 'message');
  try
    for I := 0 to Files.Count - 1 do
    begin
      Item := FindById(Result, StrToInt(Files.Names[I]));
      Item.Delete('files');
      Item.Add('files', Files.Items[I].Clone);
    end;
  finally
    Files.Free;
  end;
  for I := 0 to High(LoadHooks) do
    LoadHooks[I](Result, Ids);
end;

{ Unread messages in one room, counted to 100 at most: the sidebar shows
  99+ beyond that, and counting further would read the whole backlog. }
function UnreadIn(RoomId, LastRead, UserId: integer): integer;
begin
  Result := IntValue('SELECT COUNT(*) FROM (SELECT 1 FROM message_rooms mr' + ' JOIN messages m ON m.id = mr.message_id WHERE mr.room_id = :r AND mr.message_id > :l' +
    ' AND m.deleted = 0 AND (m.user_id IS NULL OR m.user_id <> :u) LIMIT 100) x', [RoomId, LastRead, UserId]);
end;

{ The rooms a member follows, with what is unread in each. }
function BestOfWeek(const Me: TMember): TJSONArray;
begin
  // Starts from the week's messages (index on created), not every reaction.
  Result := LoadMessages('JOIN (SELECT w.id, (SELECT COUNT(*) FROM reactions x WHERE x.message_id = w.id) AS n' +
    ' FROM messages w JOIN rooms wr ON wr.id = w.room_id WHERE w.created > ' + SqlAgo('7', suDay) +
    ' AND w.deleted = 0 AND wr.private = 0 AND wr.kind <> ''shelf'' ORDER BY n DESC, w.id DESC LIMIT 3) top' +
    ' ON top.id = m.id WHERE top.n > 0 ORDER BY top.n DESC, m.id DESC', [], Me);
end;

function RoomsList(const Me: TMember): TJSONArray;
var
  Item: TJSONObject;
  Mentions: TStringList;
  I: integer;
begin
  Result := TJSONArray.Create;
  if Me.Id = 0 then
  begin
    with Query('SELECT slug, kind, title, topic, avatar FROM rooms WHERE kind = ''channel''' + ' AND archived = 0 AND private = 0 ORDER BY id', []) do
    try
      while not EOF do
      begin
        Result.Add(TJSONObject.Create(['slug', Fields[0].AsString, 'kind', Fields[1].AsString, 'title', Fields[2].AsString, 'topic',
          Fields[3].AsString, 'private', False, 'unread', 0, 'mentions', 0, 'avatar', AvatarUrl(Fields[4].AsString)]));
        Next;
      end;
    finally
      Free;
    end;
    Exit;
  end;

  // Mentions not yet read, by room.  Only mentions newer than the oldest
  // place the member has read to are looked at.
  Mentions := TStringList.Create;
  try
    with Query('SELECT m.room_id, COUNT(*) FROM mentions n JOIN messages m ON m.id = n.message_id' + ' JOIN follows f ON f.room_id = m.room_id AND f.user_id = n.user_id' +
        ' WHERE n.user_id = :u AND n.message_id > (SELECT COALESCE(MIN(last_read_id), 0) FROM follows' +
        ' WHERE user_id = :u2) AND n.message_id > f.last_read_id AND m.deleted = 0 GROUP BY m.room_id', [Me.Id, Me.Id]) do
    try
      while not EOF do
      begin
        Mentions.Values[Fields[0].AsString] := Fields[1].AsString;
        Next;
      end;
    finally
      Free;
    end;

    with Query('SELECT r.id, r.slug, r.kind, r.title, r.topic, r.private, f.last_read_id, r.last_message_id, r.avatar, r.owner_id, f.notify' +
        ' FROM follows f JOIN rooms r ON r.id = f.room_id WHERE f.user_id = :u AND r.archived = 0' + ' ORDER BY r.kind <> ''channel'', r.kind = ''shelf'', ' +
        SqlIf('r.kind = ''channel''', 'r.id', '0') + ',' + ' r.last_talk DESC LIMIT 300', [Me.Id]) do
    try
      while not EOF do
      begin
        // owner: this member opened it, so the sidebar can offer to delete a private one
        Item := TJSONObject.Create(['slug', Fields[1].AsString, 'kind', Fields[2].AsString, 'title', Fields[3].AsString, 'topic',
          Fields[4].AsString, 'private', Fields[5].AsInteger = 1, 'mentions', StrToIntDef(Mentions.Values[Fields[0].AsString], 0), 'avatar',
          AvatarUrl(Fields[8].AsString), 'owner', Fields[9].AsInteger = Me.Id, 'notify', NotifyWord(Fields[10].AsInteger)]);
        // Rooms nothing new was said in cost nothing more.
        if Fields[7].AsInteger > Fields[6].AsInteger then
          Item.Add('unread', -Fields[0].AsInteger)   // counted below
        else
          Item.Add('unread', 0);
        Result.Add(Item);
        Next;
      end;
    finally
      Free;
    end;
  finally
    Mentions.Free;
  end;
  for I := 0 to Result.Count - 1 do
  begin
    Item := Result.Objects[I];
    if Item.Integers['unread'] < 0 then
      Item.Integers['unread'] := UnreadIn(-Item.Integers['unread'], IntValue('SELECT last_read_id FROM follows WHERE user_id = :u AND room_id = :r',
        [Me.Id, -Item.Integers['unread']]), Me.Id);
  end;
end;

{ GET /api/rooms }
procedure ShowRooms(ARequest: TRequest; AResponse: TResponse);
begin
  CheckConnection;
  SendJSON(AResponse, RoomsList(CurrentMember(ARequest)));
end;

function ReadableRoom(ARequest: TRequest; AResponse: TResponse; const Slug: string; out Me: TMember; out Room: TRoom): boolean;
begin
  Me := CurrentMember(ARequest);
  Room := FindRoom(Slug);
  Result := CanRead(Me, Room);
  if not Result then
    SendText(AResponse, 404, 'No channel by that name.');
end;

{ GET /api/messages?room=x&before=id  the 50 messages before id }
procedure ShowMessages(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Room: TRoom;
  Before: integer;
begin
  CheckConnection;
  if not ReadableRoom(ARequest, AResponse, ARequest.QueryFields.Values['room'], Me, Room) then
    Exit;
  Before := StrToIntDef(ARequest.QueryFields.Values['before'], MaxInt);
  SendJSON(AResponse, TJSONObject.Create(['messages', LoadMessages('JOIN message_rooms mr ON mr.message_id = m.id WHERE mr.room_id = :r' +
    ' AND mr.message_id < :b ORDER BY mr.message_id DESC LIMIT 50', [Room.Id, Before], Me), 'last_read',
    IntValue('SELECT last_read_id FROM follows WHERE user_id = :u AND room_id = :r', [Me.Id, Room.Id]), 'rev', IntValue('SELECT ' + RevNow, [])]));
end;

{ The room a thread (or any message) was said in. }
function RoomOfMessage(Id: integer): TRoom;
begin
  Result := RoomById(IntValue('SELECT room_id FROM messages WHERE id = :m', [Id]));
end;

{ GET /api/thread?id=  a message and its replies }
procedure ShowThread(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id: integer;
begin
  CheckConnection;
  Me := CurrentMember(ARequest);
  Id := StrToIntDef(ARequest.QueryFields.Values['id'], 0);
  if not CanRead(Me, RoomOfMessage(Id)) then
    SendText(AResponse, 404, 'That message is gone.')
  else
    SendJSON(AResponse, LoadMessages('WHERE m.id = :a OR m.parent_id = :b ORDER BY m.id LIMIT 1000', [Id, Id], Me));
end;

{ GET /api/pins?room=  }
procedure ShowPins(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Room: TRoom;
begin
  CheckConnection;
  if ReadableRoom(ARequest, AResponse, ARequest.QueryFields.Values['room'], Me, Room) then
    SendJSON(AResponse, LoadMessages('WHERE m.room_id = :r AND m.pinned = 1 AND m.deleted = 0' + ' ORDER BY m.id LIMIT 100', [Room.Id], Me));
end;

{ The words of a search in the full-text index's boolean form: each word
  must be there, and may be the start of a longer one.  Characters the
  index gives a meaning to are left out. }
function SearchWords(const Words: string): string;
var
  W, Clean: string;
  C: char;
begin
  Result := '';
  for W in Words.Split([' ', #9, #10, #13], TStringSplitOptions.ExcludeEmpty) do
  begin
    Clean := '';
    for C in W do
      if (C in ['A'..'Z', 'a'..'z', '0'..'9', '_']) or (Ord(C) >= 128) then
        Clean := Clean + C;
    if Length(Clean) >= 3 then
      Result := Result + ' +' + Clean + '*';
  end;
  Result := Trim(Result);
end;

{ GET /api/search?q=&room=  words anywhere the member may read, or in one
  room.  Words of three letters or more use the full-text index; shorter
  ones are only looked for inside one room. }
procedure Search(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Room: TRoom;
  Words, Indexed, Slug, Where: string;
begin
  CheckConnection;
  Me := CurrentMember(ARequest);
  Words := Trim(ARequest.QueryFields.Values['q']);
  Slug := ARequest.QueryFields.Values['room'];
  Indexed := SearchWords(Words);
  Room := FindRoom(Slug);
  if (Length(Words) < 2) or ((Slug <> '') and not CanRead(Me, Room)) then
    SendJSON(AResponse, TJSONArray.Create)
  else if Slug <> '' then
  begin
    if Indexed <> '' then
      Where := 'WHERE m.room_id = :r AND m.deleted = 0 AND ' + SqlMatch('m.body', ':q', True)
    else
    begin
      Where := 'WHERE m.room_id = :r AND m.deleted = 0 AND m.body LIKE :q';
      Indexed := '%' + Words + '%';
    end;
    SendJSON(AResponse, LoadMessages(Where + ' ORDER BY m.id DESC LIMIT 50', [Room.Id, Indexed], Me));
  end
  else if Indexed = '' then
    SendJSON(AResponse, TJSONArray.Create)
  else
    SendJSON(AResponse, LoadMessages('WHERE ' + SqlMatch('m.body', ':q', True) + ' AND m.deleted = 0' +
      ' AND (r.private = 0 OR r.id IN (SELECT room_id FROM follows WHERE user_id = :u))' + ' ORDER BY m.id DESC LIMIT 50', [Indexed, Me.Id], Me));
end;

{ GET /api/sync?room=x&since=rev&thread=id&read=id&here=1&rooms=1&live=id
  Everything that changed in the room (and the open thread) since rev, in
  the order it changed; more says there is more to ask for (since the rev
  of the last one).  read marks the room read up to that message; here=1
  notes the member as here and adds who is here and typing; rooms=1 adds
  the sidebar's unread counts; live is the page's live connection, which
  from now on rings for this room. }
procedure Sync(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Room: TRoom;
  Since: int64;
  Thread, ReadUpTo: integer;
  Answer: TJSONObject;
  Changed: TJSONArray;
  Hook: TSyncHook;
  Here: boolean;
begin
  CheckConnection;
  Me := CurrentMember(ARequest);
  with ARequest.QueryFields do
  begin
    Room := FindRoom(Values['room']);
    Since := StrToInt64Def(Values['since'], 0);
    Thread := StrToIntDef(Values['thread'], 0);
    ReadUpTo := StrToIntDef(Values['read'], 0);
  end;
  if not CanRead(Me, Room) then
    Room := FindRoom('');
  if (Thread > 0) and not CanRead(Me, RoomOfMessage(Thread)) then
    Thread := 0;
  Watch(ARequest.QueryFields.Values['live'], Me.Id, Room.Id, Thread);
  Here := ARequest.QueryFields.Values['here'] = '1';
  Answer := TJSONObject.Create(['rev', IntValue('SELECT ' + RevNow, [])]);
  if Room.Id > 0 then
  begin
    if Me.Id > 0 then
    begin
      if Here then
        TouchPresence(Me.Id, Room.Id);
      if ReadUpTo > 0 then
        Exec('UPDATE follows SET last_read_id = :m WHERE user_id = :u AND room_id = :r AND last_read_id < :m2',
          [ReadUpTo, Me.Id, Room.Id, ReadUpTo]);
    end;
    Changed := LoadMessages('JOIN message_rooms mr ON mr.message_id = m.id' + ' WHERE mr.room_id = :r AND mr.rev > :s ORDER BY mr.rev LIMIT 200', [Room.Id, Since], Me);
    Answer.Add('messages', Changed);
    Answer.Add('more', Changed.Count = 200);
    if Here then
    begin
      Answer.Add('typing', TypingNames(Room.Id, Me.Id));
      Answer.Add('here', HereNow(Room.Id));
    end;
  end;
  if Thread > 0 then
    Answer.Add('thread', LoadMessages('WHERE (m.id = :a OR m.parent_id = :b) AND m.rev > :s' + ' ORDER BY m.id LIMIT 1000', [Thread, Thread, Since], Me));
  if (Me.Id > 0) and (ARequest.QueryFields.Values['rooms'] = '1') then
    Answer.Add('rooms', RoomsList(Me));
  for Hook in SyncHooks do
    Hook(ARequest, Me, Answer);
  SendJSON(AResponse, Answer);
end;

{ Writing }

{ A message as anyone may see it, with the names it mentions, to ride
  along with a ring; each page works out mentions_me and ignored itself. }
function RingCopy(MessageId: integer): TJSONObject;
var
  Nobody: TMember;
  List: TJSONArray;
  Names: TJSONArray;
begin
  Nobody.Id := 0;
  Nobody.Name := '';
  Nobody.Roles := '';
  Nobody.Banned := False;
  Nobody.Verified := False;
  List := LoadMessages('WHERE m.id = :m', [MessageId], Nobody);
  try
    Result := TJSONObject(List.Extract(0));
  finally
    List.Free;
  end;
  Names := TJSONArray.Create;
  with Query('SELECT u.name FROM mentions n JOIN users u ON u.id = n.user_id WHERE n.message_id = :m', [MessageId]) do
  try
    while not EOF do
    begin
      Names.Add(Fields[0].AsString);
      Next;
    end;
  finally
    Free;
  end;
  Result.Add('names', Names);
end;

{ A message changed: give it a new revision, in its rooms too, and ring
  the pages showing them.  Fresh says it is new, so it rides along. }
procedure Touch(MessageId: integer; Fresh: boolean = False);
var
  Root: integer;
  Shown: TJSONObject;
begin
  Exec('UPDATE messages SET rev = ' + RevNow + ' WHERE id = :m', [MessageId]);
  Exec('UPDATE message_rooms mr JOIN messages m ON m.id = mr.message_id SET mr.rev = m.rev' + ' WHERE mr.message_id = :m', [MessageId]);
  Root := IntValue('SELECT COALESCE(parent_id, id) FROM messages WHERE id = :m', [MessageId]);
  Shown := nil;
  if Fresh then
    Shown := RingCopy(MessageId);
  try
    with Query('SELECT room_id FROM message_rooms WHERE message_id = :m', [Root]) do
    try
      while not EOF do
      begin
        RingRoom(RoomById(Fields[0].AsInteger), Shown);
        Next;
      end;
    finally
      Free;
    end;
  finally
    Shown.Free;
  end;
end;

procedure NoteNames(MessageId, AuthorId: integer; Members, Rooms: TStrings; TagRooms: boolean);
// TagRooms is false for replies and for anything said in a private room,
// which must never show up in a public one.
var
  S: string;
  Target: TRoom;
  Id: integer;
begin
  for S in Members do
  begin
    Id := MemberId(S);
    if (Id > 0) and (Id <> AuthorId) and not Ignores(Id, AuthorId) then
    begin
      Exec(SqlInsertIgnore('mentions', 'message_id, user_id', ':m, :u'), [MessageId, Id]);
      RingUser(Id, BellNote(['t', 'me']));
      // a channel the member silenced still counts the mention; it does not
      // push or mail about it
      if not Silenced(Id, RoomOfMessage(MessageId).Id) then
        NotifyMember(Id);
    end;
  end;
  // Naming a public room shows the message there too, while that is on
  // (off since 31 Oct 2026: a message listing the channels went to all of
  // them, and how to cross post on purpose is still to be decided).
  if TagRooms and CrossPosting then
    for S in Rooms do
    begin
      Target := FindRoom(S);
      if (Target.Id > 0) and not Target.Private and (CanStart(MemberById(AuthorId), Target) = '') then
        Exec(SqlInsertIgnoreSelect('message_rooms', 'room_id, message_id, rev', 'SELECT :r, id, rev FROM messages WHERE id = :m'), [Target.Id, MessageId]);
    end;
end;

function AddMessage(const Room: TRoom; Parent, UserId: integer; const Author, Body, Files: string): integer;
var
  Members, Rooms: TStringList;
  Html: string;
  UserValue, ParentValue: variant;
begin
  Members := TStringList.Create;
  Rooms := TStringList.Create;
  try
    Html := RenderText(Body, @MemberExists, @RoomExists, Members, Rooms);
    UserValue := Null;
    if UserId > 0 then
      UserValue := UserId;
    ParentValue := Null;
    if Parent > 0 then
      ParentValue := Parent;
    Exec('INSERT INTO messages (room_id, parent_id, user_id, author, body, html, rev) VALUES' + ' (:r, :p, :u, :a, :b, :h, ' + RevNow +
      ')', [Room.Id, ParentValue, UserValue, Author, Body, Html]);
    Result := LastId;
    if Parent = 0 then
      Exec('INSERT INTO message_rooms (room_id, message_id, rev) SELECT :r, id, rev FROM messages' + ' WHERE id = :m', [Room.Id, Result]);
    // Naming a room in a reply does not pull the reply out of its thread.
    NoteNames(Result, UserId, Members, Rooms, (Parent = 0) and not Room.Private);
  finally
    Rooms.Free;
    Members.Free;
  end;
  if Files <> '' then
    AttachFiles(Result, Room.Id, UserId, Files, 'message');
  RunMessageHooks(Result, Body);
  if UserId > 0 then
    Exec('UPDATE users SET posts = posts + 1 WHERE id = :u', [UserId]);
  Exec('UPDATE rooms SET message_count = message_count + 1 WHERE id = :r', [Room.Id]);
  if Parent > 0 then
  begin
    // The parent changes (its count), so its revision moves; the reply
    // itself rides along with the ring.
    Exec('UPDATE messages SET reply_count = reply_count + 1, last_reply = NOW(), rev = ' + RevNow + ' WHERE id = :p', [Parent]);
    Exec('UPDATE message_rooms mr JOIN messages m ON m.id = mr.message_id SET mr.rev = m.rev' + ' WHERE mr.message_id = :p', [Parent]);
    Touch(Result, True);
  end
  else
  begin
    Exec('UPDATE rooms r JOIN message_rooms mr ON mr.room_id = r.id SET r.last_talk = NOW(),' + ' r.last_message_id = :m WHERE mr.message_id = :m2', [Result, Result]);
    if UserId > 0 then
      Exec('UPDATE follows SET last_read_id = :m WHERE user_id = :u AND room_id = :r', [Result, UserId, Room.Id]);
    Touch(Result, True);
  end;
end;

function FindCommand(const Name: string): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(Commands) do
    if SameText(Commands[I].Name, Name) then
      Exit(I);
end;

{ Tells the poster, the way IRC does, that someone they named is away. }
function AwayNotes(MessageId: integer): string;
begin
  Result := '';
  with Query('SELECT u.name, u.away FROM mentions n JOIN users u ON u.id = n.user_id' + ' WHERE n.message_id = :m AND u.away <> ''''', [MessageId]) do
  try
    while not EOF do
    begin
      Result := Result + Fields[0].AsString + ' is away: ' + Fields[1].AsString + #10;
      Next;
    end;
  finally
    Free;
  end;
  Result := Trim(Result);
end;

{ Says Body as Me in Room, or in the thread Parent, the way the page posts:
  the rate limit, the room's rules and /commands.  The new message's id, or
  0 with Status the HTTP code and Info why.  Info also carries what to tell
  Me after a post (a command's answer, who is away), Go a page to open. }
function Say(const Me: TMember; Room: TRoom; Parent: integer; Body: string; const Files: string; out Info, Go: string; out Status: integer): integer;
var
  Command: integer;
  Why, Name: string;
  Said: TCommandResult;
begin
  Result := 0;
  Info := '';
  Go := '';
  Status := 200;
  Body := Trim(Body);
  if not Me.Verified then
  begin
    Status := 403;
    Info := 'Confirm your email first: the link is in the mail we sent you.';
    Exit;
  end;
  if IntValue('SELECT COUNT(*) FROM messages WHERE user_id = :u AND created > ' + SqlAgo('10', suSecond), [Me.Id]) >= 10 then
  begin
    Status := 429;
    Info := 'Slow down a little.';
    Exit;
  end;
  // A reply goes where its thread started, and anyone who may talk there
  // may reply, even in a read-only room.
  if Parent > 0 then
  begin
    Room := RoomById(IntValue('SELECT room_id FROM messages WHERE id = :p AND parent_id IS NULL', [Parent]));
    Why := '';
    if not CanRead(Me, Room) then
      Why := 'That thread is gone.'
    else if Room.Archived then
      Why := 'This channel is archived.'
    else if not RoomCan(Me, 'post', Room) then
      Why := 'Posting is not open to you here.';
  end
  else
    Why := CanStart(Me, Room);
  // Commands work anywhere the member can read, even where they cannot post.
  if Body.StartsWith('/') and CanRead(Me, Room) then
  begin
    Name := Copy(Body, 2, Pos(' ', Body + ' ') - 2);
    Command := FindCommand(Name);
    if Command < 0 then
    begin
      Status := 400;
      Info := 'There is no /' + Name + '. Type /help to see the commands.';
      Exit;
    end;
    Said := Commands[Command].Func(Me, Room, Parent, Trim(Copy(Body, Length(Name) + 2, MaxInt)));
    Body := Said.Post;
    Info := Said.Info;
    Go := Said.Go;
    if Body = '' then
      Exit;
  end;
  if Why <> '' then
    Status := 403
  else if (Body = '') and (Files = '') then
  begin
    Status := 400;
    Why := 'Nothing to send.';
  end
  else if Length(Body) > MaxBody then
  begin
    Status := 400;
    Why := Format('A message is %d characters at most. Long code fits better in a file.', [MaxBody]);
  end;
  if Status <> 200 then
  begin
    Info := Why;
    Exit;
  end;
  Result := AddMessage(Room, Parent, Me.Id, Me.Name, Body, Files);
  Info := Trim(Info + #10 + AwayNotes(Result));
end;

{ POST /api/post  room, parent, body, files (tokens from /api/upload) }
procedure Post(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id, Status: integer;
  Info, Go: string;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  with ARequest.ContentFields do
    Id := Say(Me, FindRoom(Values['room']), StrToIntDef(Values['parent'], 0), Values['body'], Values['files'], Info, Go, Status);
  if Status <> 200 then
    SendText(AResponse, Status, Info)
  else
    SendJSON(AResponse, TJSONObject.Create(['id', Id, 'info', Info, 'go', Go]));
end;

{ POST /api/edit  id, body: the author's own message }
procedure Edit(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id: integer;
  Body, Html: string;
  Members, Rooms: TStringList;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Id := StrToIntDef(ARequest.ContentFields.Values['id'], 0);
  Body := Trim(ARequest.ContentFields.Values['body']);
  if (IntValue('SELECT COUNT(*) FROM messages WHERE id = :m AND user_id = :u AND deleted = 0', [Id, Me.Id]) = 0) or not Can(Me, 'edit-own') then
  begin
    SendText(AResponse, 403, 'Only your own messages can be edited.');
    Exit;
  end;
  if (Body = '') or (Length(Body) > MaxBody) then
  begin
    SendText(AResponse, 400, 'An edited message cannot be empty or too long. Delete it instead.');
    Exit;
  end;
  Members := TStringList.Create;
  Rooms := TStringList.Create;
  try
    Html := RenderText(Body, @MemberExists, @RoomExists, Members, Rooms);
    Exec('UPDATE messages SET body = :b, html = :h, edited = 1 WHERE id = :m', [Body, Html, Id]);
    NoteNames(Id, Me.Id, Members, Rooms, (IntValue('SELECT COUNT(*) FROM messages WHERE id = :m' + ' AND parent_id IS NULL', [Id]) > 0) and not RoomOfMessage(Id).Private);
  finally
    Rooms.Free;
    Members.Free;
  end;
  RunMessageHooks(Id, Body);
  Touch(Id);
  SendText(AResponse, 200, 'ok');
end;

{ POST /api/delete  id: the author, or whoever may delete any message there }
procedure Remove(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id, Author, Parent: integer;
  Room: TRoom;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Id := StrToIntDef(ARequest.ContentFields.Values['id'], 0);
  Author := IntValue('SELECT user_id FROM messages WHERE id = :m', [Id]);
  Room := RoomOfMessage(Id);
  if not ((Author = Me.Id) and Can(Me, 'delete-own')) and not RoomCan(Me, 'delete-any', Room) then
  begin
    SendText(AResponse, 403, 'That is not yours to delete.');
    Exit;
  end;
  Exec('UPDATE messages SET body = '''', html = '''', deleted = 1, pinned = 0 WHERE id = :m', [Id]);
  DeleteFilesOf(Id, 'message');
  Parent := IntValue('SELECT parent_id FROM messages WHERE id = :m', [Id]);
  if Parent > 0 then
    Exec('UPDATE messages SET reply_count = ' + SqlGreatest('reply_count - 1', '0') + ' WHERE id = :p', [Parent]);
  Touch(Id);
  if Parent > 0 then
    Touch(Parent);
  SendText(AResponse, 200, 'ok');
end;

{ POST /api/react  id, r: adds the member's reaction or takes it back }
procedure React(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id, R: integer;
  Room: TRoom;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  Id := StrToIntDef(ARequest.ContentFields.Values['id'], 0);
  R := StrToIntDef(ARequest.ContentFields.Values['r'], -1);
  Room := RoomOfMessage(Id);
  if (R < 0) or (R > High(Reactions)) then
    SendText(AResponse, 400, 'No such reaction.')
  else if not CanRead(Me, Room) or not RoomCan(Me, 'react', Room) then
    SendText(AResponse, 403, 'Reactions are not open to you here.')
  else
  begin
    if IntValue('SELECT COUNT(*) FROM reactions WHERE message_id = :m AND user_id = :u AND reaction = :r', [Id, Me.Id, R]) > 0 then
      Exec('DELETE FROM reactions WHERE message_id = :m AND user_id = :u AND reaction = :r', [Id, Me.Id, R])
    else
      Exec('INSERT INTO reactions (message_id, user_id, reaction) SELECT id, :u, :r FROM messages' + ' WHERE id = :m AND deleted = 0', [Me.Id, R, Id]);
    Touch(Id);
    SendText(AResponse, 200, 'ok');
  end;
end;

{ POST /api/pin  id }
procedure Pin(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  Id: integer;
begin
  CheckConnection;
  Me := CurrentMember(ARequest);
  Id := StrToIntDef(ARequest.ContentFields.Values['id'], 0);
  if not RoomCan(Me, 'pin', RoomOfMessage(Id)) then
  begin
    SendText(AResponse, 403, 'Only the channel''s owner or a moderator pins messages.');
    Exit;
  end;
  Exec('UPDATE messages SET pinned = 1 - pinned WHERE id = :m', [Id]);
  Touch(Id);
  SendText(AResponse, 200, 'ok');
end;

{ GET /api/commands  for the message box's suggestions }
procedure ShowCommands(ARequest: TRequest; AResponse: TResponse);
var
  List: TJSONArray;
  C: TCommand;
begin
  List := TJSONArray.Create;
  for C in Commands do
    List.Add(TJSONObject.Create(['name', C.Name, 'usage', C.Usage]));
  SendJSON(AResponse, List);
end;

{ Commands every site has; ChatCommands adds the IRC ones. }

function HelpCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Lines: string;
  C: TCommand;
begin
  Lines := '';
  for C in Commands do
    Lines := Lines + C.Usage + #10;
  Result := CommandResult('', Lines + '/msg name text - a private message');
end;

function MeCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
begin
  if Args = '' then
    Result := CommandResult('', 'Use: /me does something')
  else
    Result := CommandResult('*' + Me.Name + ' ' + Args + '*', '');
end;

function TopicCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
begin
  if not RoomCan(Me, 'set-topic', Room) then
    Exit(CommandResult('', 'Only the channel''s owner or a moderator changes its topic.'));
  Exec('UPDATE rooms SET topic = :t WHERE id = :r', [Copy(Args, 1, 500), Room.Id]);
  Result := CommandResult('changed the topic: ' + Args, '');
end;

{ Messages keep the HTML made when they were sent, so code written before
  a language was colored stays plain.  Once for each CODE_COLORS, at
  startup: every message with a code block is shaped again from its own
  words. }
procedure ColorOldCode;
const
  CODE_COLORS = '4';
var
  Members, Rooms, Ids, Bodies: TStringList;
  I: integer;
begin
  if Setting('code_colors', '') = CODE_COLORS then
    Exit;
  Members := TStringList.Create;
  Rooms := TStringList.Create;
  Ids := TStringList.Create;
  Bodies := TStringList.Create;
  try
    with Query('SELECT id, body FROM messages WHERE deleted = 0 AND body LIKE ''%```%''', []) do
    try
      while not EOF do
      begin
        Ids.Add(Fields[0].AsString);
        Bodies.Add(Fields[1].AsString);
        Next;
      end;
    finally
      Free;
    end;
    for I := 0 to Ids.Count - 1 do
    begin
      Members.Clear;
      Rooms.Clear;
      Exec('UPDATE messages SET html = :h WHERE id = :m', [RenderText(Bodies[I], @MemberExists, @RoomExists, Members, Rooms), StrToInt(Ids[I])]);
    end;
    SaveSetting('code_colors', CODE_COLORS);
    Log('Code blocks colored again in ' + IntToStr(Ids.Count) + ' messages');
  finally
    Bodies.Free;
    Ids.Free;
    Rooms.Free;
    Members.Free;
  end;
end;

initialization
  RegisterTable('CREATE TABLE IF NOT EXISTS messages (' + ' id INT AUTO_INCREMENT PRIMARY KEY,' + ' room_id INT NOT NULL,' +
    ' parent_id INT NULL,' + ' user_id INT NULL,' + ' author VARCHAR(40) NOT NULL,' + ' body TEXT NOT NULL,' + ' html MEDIUMTEXT NOT NULL,' +
    ' pinned TINYINT NOT NULL DEFAULT 0,' + ' edited TINYINT NOT NULL DEFAULT 0,' + ' deleted TINYINT NOT NULL DEFAULT 0,' +
    ' reply_count INT NOT NULL DEFAULT 0,' + ' last_reply DATETIME NULL,' + ' created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,' +
    ' rev BIGINT UNSIGNED NOT NULL,' + ' INDEX (parent_id), INDEX (user_id, created), INDEX (room_id, pinned), INDEX (room_id, created),' +
    ' INDEX (room_id, user_id), INDEX (created),' + ' FULLTEXT (body)' + ') CHARACTER SET utf8mb4');
  // The rooms a message that starts a thread shows in: where it was said,
  // and each public #room it names.  rev copies the message's, so a room's
  // changes are one index range.
  RegisterTable('CREATE TABLE IF NOT EXISTS message_rooms (' + ' room_id INT NOT NULL, message_id INT NOT NULL, rev BIGINT UNSIGNED NOT NULL,' +
    ' PRIMARY KEY (room_id, message_id), INDEX (message_id), INDEX (room_id, rev))');
  RegisterTable('CREATE TABLE IF NOT EXISTS reactions (' + ' message_id INT NOT NULL, user_id INT NOT NULL, reaction TINYINT NOT NULL,' +
    ' PRIMARY KEY (message_id, user_id, reaction))');
  RegisterTable('CREATE TABLE IF NOT EXISTS mentions (' + ' message_id INT NOT NULL, user_id INT NOT NULL,' + ' PRIMARY KEY (user_id, message_id))');
  RegisterStartup(@ColorOldCode);
  RegisterPermission('react', 'React to messages', 'member');
  RegisterPermission('edit-own', 'Edit their own messages', 'member');
  RegisterPermission('delete-own', 'Delete their own messages', 'member');
  RegisterPermission('delete-any', 'Delete anyone''s messages', 'owner,room-moderator,moderator,admin');
  RegisterPermission('pin', 'Pin messages', 'owner,room-moderator,moderator,admin');
  RegisterCommand('help', '/help - these commands', @HelpCommand);
  RegisterCommand('me', '/me does something - says it as an action', @MeCommand);
  RegisterCommand('topic', '/topic text - sets the channel''s topic', @TopicCommand);
  HTTPRouter.RegisterRoute('/api/rooms', rmGet, @ShowRooms);
  HTTPRouter.RegisterRoute('/api/commands', rmGet, @ShowCommands);
  HTTPRouter.RegisterRoute('/api/messages', rmGet, @ShowMessages);
  HTTPRouter.RegisterRoute('/api/thread', rmGet, @ShowThread);
  HTTPRouter.RegisterRoute('/api/pins', rmGet, @ShowPins);
  HTTPRouter.RegisterRoute('/api/search', rmGet, @Search);
  HTTPRouter.RegisterRoute('/api/sync', rmGet, @Sync);
  HTTPRouter.RegisterRoute('/api/post', rmPost, @Post);
  HTTPRouter.RegisterRoute('/api/edit', rmPost, @Edit);
  HTTPRouter.RegisterRoute('/api/delete', rmPost, @Remove);
  HTTPRouter.RegisterRoute('/api/react', rmPost, @React);
  HTTPRouter.RegisterRoute('/api/pin', rmPost, @Pin);
end.
