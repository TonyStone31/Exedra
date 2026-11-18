unit Forum;

{$mode objfpc}{$H+}

interface

uses SysUtils, ForumSwitch, httpdefs, fpjson, ChatUsers;

type
  EForumRequest = class(Exception)
  public
    Code: integer;
    constructor Create(Status: integer; const Words: string);
  end;

function Moderate(const Me: TMember): boolean;
function Writable(const Me: TMember): boolean;
{ What a post box is told when this member may add files: the largest
  file in MB and the kinds accepted, as attributes; '' when he may not. }
function ForumUploadAttributes(const Me: TMember): string;
function Boards(const Me: TMember; All: boolean): TJSONArray;
function BoardPage(Id, Page: integer; const Me: TMember): TJSONObject;
function TopicPage(Id, Page: integer; const Me: TMember; PostId: integer = 0): TJSONObject;
function Search(const Text: string; Page: integer; const Me: TMember): TJSONObject;
function PostPage(Id, PostId: integer; const Me: TMember): integer;
function Categories: TJSONArray;
function ForumInfo(const Me: TMember): TJSONObject;
function Recent(Page: integer; const Me: TMember; Unread: boolean): TJSONObject;
procedure Refuse(Status: integer; const Words: string);

implementation

uses
  Classes, Variants, sqldb, httproute,
  ChatDb, ChatRoles, ChatAdmin, ChatGuard, ChatMarkup, ChatFiles, SiteWords, SiteSql,
  ForumRules, ForumPages;

type
  TForumTopic = record
    Id, BoardId, AuthorId, FirstPostId: integer;
    Hidden, Locked: boolean;
  end;

constructor EForumRequest.Create(Status: integer; const Words: string);
begin
  inherited Create(Words);
  Code := Status;
end;

procedure Refuse(Status: integer; const Words: string);
begin
  raise EForumRequest.Create(Status, Words);
end;

function Moderate(const Me: TMember): boolean;
begin
  Result := (Me.Id > 0) and not Me.Banned and Can(Me, 'forum-moderate');
end;

function Writable(const Me: TMember): boolean;
begin
  Result := ForumMayWrite(Me.Id, Me.Banned, Me.Verified, Can(Me, 'forum-post'));
end;

procedure NeedWrite(const Me: TMember);
begin
  if not Writable(Me) then
    Refuse(403, 'You cannot post in the forum.');
end;

function Number(const Text: string): integer;
begin
  Result := StrToIntDef(Text, 0);
  if Result <= 0 then
    Refuse(400, 'Enter a valid number.');
end;

function Field(R: TRequest; const Name: string): string;
begin
  Result := R.ContentFields.Values[Name];
end;

function OptionalNumber(R: TRequest; const Name: string): integer;
var
  Text: string;
begin
  Result := 0;
  Text := Field(R, Name);
  if (Text <> '') and not TryStrToInt(Text, Result) then
    Refuse(400, 'Enter a valid number.');
end;

procedure CheckText(const Text: string; MaxBytes: integer; SingleLine: boolean);
var
  Problem: string;
begin
  Problem := ForumTextProblem(Text, MaxBytes, SingleLine);
  if Problem <> '' then
    Refuse(400, Problem);
end;

function Flag(R: TRequest; const Name: string): integer;
begin
  if not (Field(R, Name) = '0') and not (Field(R, Name) = '1') then
    Refuse(400, 'Use 0 or 1 for this option.');
  Result := StrToInt(Field(R, Name));
end;

procedure NeedBoard(const Me: TMember; Id: integer);
begin
  with Query('SELECT b.read_permission, b.parent_id, p.id, p.read_permission' + ' FROM forum_boards b LEFT JOIN forum_boards p ON p.id = b.parent_id WHERE b.id = :b',
      [Id]) do
  try
    if EOF then
      Refuse(404, 'Nothing here.');
    if not ForumMayReadBoard(Can(Me, Fields[0].AsString), not Fields[1].IsNull, not Fields[2].IsNull, Can(Me, Fields[3].AsString)) then
      Refuse(404, 'Nothing here.');
  finally
    Free;
  end;
end;

function ReadableBoards(const Me: TMember): string;
begin
  Result := '';
  with Query('SELECT b.id, b.read_permission, b.parent_id, p.id, p.read_permission' +
      ' FROM forum_boards b LEFT JOIN forum_boards p ON p.id = b.parent_id ORDER BY b.id', []) do
  try
    while not EOF do
    begin
      if ForumMayReadBoard(Can(Me, Fields[1].AsString), not Fields[2].IsNull, not Fields[3].IsNull, Can(Me, Fields[4].AsString)) then
      begin
        if Result <> '' then
          Result := Result + ',';
        Result := Result + IntToStr(Fields[0].AsInteger);
      end;
      Next;
    end;
  finally
    Free;
  end;
end;

procedure LockBoard(Id: integer);
begin
  with Query('SELECT id FROM forum_boards WHERE id = :b FOR UPDATE', [Id]) do
  try
    if EOF then
      Refuse(404, 'Nothing here.');
  finally
    Free;
  end;
end;

function GetTopic(const Me: TMember; Id: integer; LockRow: boolean): TForumTopic;
var
  S: string;
begin
  S := '';
  if LockRow then
    S := ' FOR UPDATE';
  with Query('SELECT id, board_id, author_id, first_post_id, hidden, locked' + ' FROM forum_topics WHERE id = :t' + S, [Id]) do
  try
    if EOF then
      Refuse(404, 'Nothing here.');
    Result.Id := Fields[0].AsInteger;
    Result.BoardId := Fields[1].AsInteger;
    Result.AuthorId := Fields[2].AsInteger;
    Result.FirstPostId := Fields[3].AsInteger;
    Result.Hidden := Fields[4].AsInteger <> 0;
    Result.Locked := Fields[5].AsInteger <> 0;
  finally
    Free;
  end;
  NeedBoard(Me, Result.BoardId);
  if Result.Hidden and not Moderate(Me) then
    Refuse(404, 'Nothing here.');
end;

function LockTopic(const Me: TMember; Id: integer; Destination: integer = 0): TForumTopic;
var
  BoardId: integer;
begin
  BoardId := IntValue('SELECT board_id FROM forum_topics WHERE id = :t', [Id]);
  if BoardId = 0 then
    Refuse(404, 'Nothing here.');
  if (Destination > 0) and (Destination < BoardId) then
    LockBoard(Destination);
  LockBoard(BoardId);
  if Destination > BoardId then
    LockBoard(Destination);
  Result := GetTopic(Me, Id, True);
  if Result.BoardId <> BoardId then
    Refuse(409, 'The topic moved. Try again.');
end;

{ Stored positions let page and post links use indexed lookups after moderation. }
procedure RefreshPositions(Id: integer);
var
  Q: TSQLQuery;
  N, VisibleN: integer;
begin
  N := 0;
  VisibleN := 0;
  Q := Query('SELECT p.id, p.hidden, t.first_post_id FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id WHERE t.id = :t ORDER BY p.created, p.id', [Id]);
  try
    while not Q.EOF do
    begin
      Inc(N);
      if (Q.Fields[1].AsInteger = 0) or (Q.Fields[0].AsInteger = Q.Fields[2].AsInteger) then Inc(VisibleN);
      Exec('UPDATE forum_posts SET position = :n, visible_position = :v WHERE id = :p', [N, VisibleN, Q.Fields[0].AsInteger]);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  Exec('UPDATE forum_topics SET post_count = :n, display_count = :v WHERE id = :t', [N, VisibleN, Id]);
end;

procedure RefreshMember(UserId: integer);
begin
  Exec(SqlInsertIgnore('forum_members', 'user_id', ':u'), [UserId]);
  with Query('SELECT user_id FROM forum_members WHERE user_id = :u FOR UPDATE', [UserId]) do Free;
  Exec('INSERT INTO forum_members (user_id, post_count) SELECT :u, COUNT(*) FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id WHERE p.author_id = :a AND p.hidden = 0 AND t.hidden = 0'
    + SqlOnConflict('user_id', 'post_count = ' + SqlNew('post_count')), [UserId, UserId]);
end;

procedure RefreshTopicMembers(Id: integer);
var
  Q: TSQLQuery;
begin
  Q := Query('SELECT DISTINCT author_id FROM forum_posts WHERE topic_id = :t ORDER BY author_id', [Id]);
  try
    while not Q.EOF do
    begin
      RefreshMember(Q.Fields[0].AsInteger);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure NewForumMember(UserId: integer);
begin
  Exec(SqlInsertIgnore('forum_members', 'user_id', ':u'), [UserId]);
  Exec('UPDATE forum_totals SET members = members + 1 WHERE id = 1', []);
end;

{ Counts are repaired on removals and moderation, never on list requests. }
procedure RefreshTopic(Id: integer);
begin
  Exec('UPDATE forum_topics t SET reply_count = (SELECT COUNT(*) FROM forum_posts p' + ' WHERE p.topic_id = t.id AND p.id <> t.first_post_id AND p.hidden = 0),' +
    ' last_post_id = (SELECT p.id FROM forum_posts p WHERE p.topic_id = t.id AND p.hidden = 0 ORDER BY p.created DESC, p.id DESC LIMIT 1),' +
    ' last_post_at = COALESCE((SELECT p.created FROM forum_posts p WHERE p.topic_id = t.id AND p.hidden = 0' +
    ' ORDER BY p.created DESC, p.id DESC LIMIT 1), t.created),' + ' last_post_author = COALESCE((SELECT p.author_id FROM forum_posts p WHERE p.topic_id = t.id AND p.hidden = 0'
    + ' ORDER BY p.created DESC, p.id DESC LIMIT 1), t.author_id) WHERE t.id = :t', [Id]);
end;

procedure RefreshBoard(Id: integer);
begin
  Exec('UPDATE forum_boards b SET total_topic_count = (SELECT COUNT(*) FROM forum_topics t WHERE t.board_id = b.id), topic_count = (SELECT COUNT(*) FROM forum_topics t WHERE t.board_id = b.id AND t.hidden = 0),'
    + ' post_count = (SELECT COUNT(*) FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id' + ' WHERE t.board_id = b.id AND t.hidden = 0 AND p.hidden = 0),' +
    ' last_topic_id = (SELECT t.id FROM forum_topics t WHERE t.board_id = b.id AND t.hidden = 0 AND t.last_post_id IS NOT NULL ORDER BY t.last_post_at DESC, t.id DESC LIMIT 1),' +
    ' last_post_at = (SELECT t.last_post_at FROM forum_topics t WHERE t.board_id = b.id AND t.hidden = 0 AND t.last_post_id IS NOT NULL' +
    ' ORDER BY t.last_post_at DESC, t.id DESC LIMIT 1),' +
    ' unread_topic_count = (SELECT COUNT(*) FROM forum_topics t WHERE t.board_id = b.id AND t.hidden = 0 AND t.last_post_id IS NOT NULL),' +
    ' last_post_author = (SELECT t.last_post_author FROM forum_topics t WHERE t.board_id = b.id AND t.hidden = 0 AND t.last_post_id IS NOT NULL' +
    ' ORDER BY t.last_post_at DESC, t.id DESC LIMIT 1) WHERE b.id = :b', [Id]);
  Exec('UPDATE forum_board_reads br SET unread_count = (SELECT COUNT(*) FROM forum_topics t LEFT JOIN forum_topic_reads tr ON tr.topic_id = t.id AND tr.user_id = br.user_id WHERE t.board_id = br.board_id AND t.hidden = 0 AND t.last_post_id > COALESCE(tr.post_id, 0) AND t.last_post_at > br.read_at) WHERE br.board_id = :b', [Id]);
end;

procedure NotePost(TopicId, BoardId, AuthorId, PostId: integer; NewTopic: boolean);
var
  BecameReadable: integer;
begin
  BecameReadable := Ord(IntValue('SELECT COALESCE(last_post_id, 0) FROM forum_topics WHERE id = :t', [TopicId]) = 0);
  Exec('UPDATE forum_board_reads SET unread_count = unread_count + 1 WHERE board_id = :b AND EXISTS (SELECT 1 FROM forum_topics t WHERE t.id = :t2' +
    ' AND (t.last_post_id IS NULL OR t.last_post_id <= COALESCE((SELECT tr.post_id FROM forum_topic_reads tr WHERE tr.user_id = forum_board_reads.user_id AND tr.topic_id = :t), 0)'
    + ' OR t.last_post_at <= forum_board_reads.read_at))', [BoardId, TopicId, TopicId]);
  Exec('UPDATE forum_topics SET reply_count = reply_count + :n,' + ' last_post_at = (SELECT created FROM forum_posts WHERE id = :p),' +
    ' last_post_author = :u, last_post_id = :p2, post_count = post_count + 1, display_count = display_count + 1 WHERE id = :t',
    [Ord(not NewTopic), PostId, AuthorId, PostId, TopicId]);
  Exec('UPDATE forum_posts SET position = (SELECT post_count FROM forum_topics WHERE id = :t), visible_position = (SELECT display_count FROM forum_topics WHERE id = :t2) WHERE id = :p', [TopicId, TopicId, PostId]);
  Exec('INSERT INTO forum_members (user_id, post_count) VALUES (:u, 1)' + SqlOnConflict('user_id', 'post_count = post_count + 1'), [AuthorId]);
  Exec('UPDATE forum_boards SET total_topic_count = total_topic_count + :n0, topic_count = topic_count + :n, post_count = post_count + 1,' +
    ' last_post_at = (SELECT created FROM forum_posts WHERE id = :p), last_post_author = :u, last_topic_id = :t, unread_topic_count = unread_topic_count + :n2 WHERE id = :b',
    [Ord(NewTopic), Ord(NewTopic), PostId, AuthorId, TopicId, BecameReadable, BoardId]);
end;

{$push}{$warn 5024 off}
function NoName(const Name: string): boolean;
begin
  Result := False;
end;
{$pop}

function PostHtml(const Body: string): string;
var
  Members, Rooms: TStringList;
begin
  Members := TStringList.Create;
  Rooms := TStringList.Create;
  try
    Result := RenderText(Body, @NoName, @NoName, Members, Rooms);
  finally
    Rooms.Free;
    Members.Free;
  end;
end;

function BoardJSON(Q: TSQLQuery; ShowHidden: boolean): TJSONObject;
begin
  Result := TJSONObject.Create(['id', Q.FieldByName('id').AsInteger, 'name', Q.FieldByName('name').AsString, 'slug', Q.FieldByName('slug').AsString,
    'category_id', Q.FieldByName('category_id').AsInteger, 'category', Q.FieldByName('category_name').AsString, 'category_position',
    Q.FieldByName('category_position').AsInteger, 'last_topic_id', Q.FieldByName('last_topic_id').AsInteger, 'last_post_id',
    Q.FieldByName('last_post_id').AsInteger, 'last_title', Q.FieldByName('last_title').AsString, 'unread', Q.FieldByName('is_unread').AsInteger <>
    0, 'description', Q.FieldByName('description').AsString, 'position', Q.FieldByName('position').AsInteger, 'parent_id',
    Q.FieldByName('parent_id').AsInteger, 'read_permission', Q.FieldByName('read_permission').AsString, 'topic_count', Q.FieldByName('topic_count').AsLargeInt,
    'post_count', Q.FieldByName('post_count').AsLargeInt, 'last_post_at', Q.FieldByName('last_at').AsString, 'last_post_author',
    Q.FieldByName('last_post_author').AsInteger, 'last_post_name', Q.FieldByName('last_name').AsString]);
  if ShowHidden then Result.Add('total_topic_count', Q.FieldByName('total_topic_count').AsLargeInt);
end;

function UnreadWhere(UserId: integer): string;
begin
  if UserId <= 0 then Exit('0 = 1');
  Result := 't.hidden = 0 AND t.last_post_id > COALESCE((SELECT r.post_id FROM forum_topic_reads r WHERE r.user_id = ' + IntToStr(UserId) +
    ' AND r.topic_id = t.id), 0)' + ' AND t.last_post_at > COALESCE((SELECT r.read_at FROM forum_board_reads r WHERE r.user_id = ' +
    IntToStr(UserId) + ' AND r.board_id = t.board_id), ''1000-01-01'')';
end;

function BoardSelect: string;
begin
  Result := 'SELECT b.*, COALESCE(c.name, '''') AS category_name, COALESCE(c.position, 0) AS category_position, COALESCE(u.name, '''') AS last_name, lt.last_post_id, lt.title AS last_title,'
    + ' COALESCE(br.unread_count, 0) AS is_unread, ';
end;

function BoardJoins(const Me: TMember): string;
begin
  Result := ' FROM forum_boards b LEFT JOIN users u ON u.id = b.last_post_author LEFT JOIN forum_categories c ON c.id = b.category_id LEFT JOIN forum_topics lt ON lt.id = b.last_topic_id LEFT JOIN forum_board_reads br ON br.board_id = b.id AND br.user_id = ' + IntToStr(Me.Id);
end;

procedure EnsureBoardReads(const Me: TMember; const Ids: string);
begin
  if (Me.Id > 0) and (Ids <> '') then
    Exec(SqlInsertIgnoreSelect('forum_board_reads', 'user_id, board_id, read_at, unread_count',
      'SELECT :u, id, ''1000-01-01'', unread_topic_count FROM forum_boards WHERE id IN (' + Ids + ') ORDER BY id FOR UPDATE'), [Me.Id]);
end;

function Boards(const Me: TMember; All: boolean): TJSONArray;
var
  Ids: string;
  Q: TSQLQuery;
begin
  Result := TJSONArray.Create;
  try
    Ids := ReadableBoards(Me);
    EnsureBoardReads(Me, Ids);
    if All then
      Ids := ''
    else if Ids = '' then
      Exit;
    if Ids <> '' then
      Ids := ' WHERE b.id IN (' + Ids + ')';
    Q := Query(BoardSelect + IsoTime('b.last_post_at') + ' AS last_at' + BoardJoins(Me) + Ids + ' ORDER BY COALESCE(c.position, 0), COALESCE(c.id, 0), b.position, b.id', []);
    try
      while not Q.EOF do
      begin
        Result.Add(BoardJSON(Q, Moderate(Me)));
        Q.Next;
      end;
    finally
      Q.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TopicJSON(Q: TSQLQuery; ShowHidden: boolean): TJSONObject;
begin
  Result := TJSONObject.Create(['id', Q.FieldByName('id').AsInteger, 'board_id', Q.FieldByName('board_id').AsInteger, 'title',
    Q.FieldByName('title').AsString, 'author_id', Q.FieldByName('author_id').AsInteger, 'author', Q.FieldByName('author_name').AsString,
    'created', Q.FieldByName('created_at').AsString, 'last_post_at', Q.FieldByName('last_at').AsString, 'last_post_author',
    Q.FieldByName('last_post_author').AsInteger, 'last_post_name', Q.FieldByName('last_name').AsString, 'reply_count',
    Q.FieldByName('reply_count').AsLargeInt, 'view_count', Q.FieldByName('view_count').AsLargeInt, 'pinned', Q.FieldByName('pinned').AsInteger <>
    0, 'locked', Q.FieldByName('locked').AsInteger <> 0, 'hidden', Q.FieldByName('hidden').AsInteger <> 0, 'moved_from',
    Q.FieldByName('moved_from').AsInteger, 'first_post_id', Q.FieldByName('first_post_id').AsInteger, 'last_post_id', Q.FieldByName('last_post_id').AsInteger,
    'unread', Q.FieldByName('is_unread').AsInteger <> 0, 'display_count', Q.FieldByName('display_count').AsInteger]);
  if ShowHidden then
  begin
    Result.Add('post_count', Q.FieldByName('post_count').AsInteger);
    Result.Add('hidden_by', Q.FieldByName('hidden_by').AsInteger);
    Result.Add('hidden_name', Q.FieldByName('hidden_name').AsString);
    Result.Add('hidden_reason', Q.FieldByName('hidden_reason').AsString);
    Result.Add('hidden_at', Q.FieldByName('hidden_time').AsString);
  end;
end;

function TopicSelect(const Me: TMember): string;
begin
  Result := 'SELECT t.*, (' + UnreadWhere(Me.Id) + ') AS is_unread, COALESCE(a.name, '''') AS author_name, COALESCE(u.name, '''') AS last_name, ' +
    IsoTime('t.created') + ' AS created_at, ' + IsoTime('t.last_post_at') + ' AS last_at, ' + IsoTime('t.hidden_at') +
    ' AS hidden_time, COALESCE(h.name, '''') AS hidden_name' +
    ' FROM forum_topics t LEFT JOIN users a ON a.id = t.author_id LEFT JOIN users u ON u.id = t.last_post_author LEFT JOIN users h ON h.id = t.hidden_by';
end;

function BoardPage(Id, Page: integer; const Me: TMember): TJSONObject;
var
  List: TJSONArray;
  Q: TSQLQuery;
begin
  NeedBoard(Me, Id);
  EnsureBoardReads(Me, IntToStr(Id));
  Result := TJSONObject.Create(['page', Page, 'page_size', ForumPageSize]);
  try
    Q := Query(BoardSelect + IsoTime('b.last_post_at') + ' AS last_at' + BoardJoins(Me) + ' WHERE b.id = :b', [Id]);
    try
      if Q.EOF then
        Refuse(404, 'Nothing here.');
      Result.Add('board', BoardJSON(Q, Moderate(Me)));
    finally
      Q.Free;
    end;
    List := TJSONArray.Create;
    Result.Add('topics', List);
    Q := Query(TopicSelect(Me) + ' WHERE ' + ForumTopicWhere(IntToStr(Id), Moderate(Me)) + ' ORDER BY t.pinned DESC, t.last_post_at DESC, t.id DESC LIMIT :n OFFSET :o',
      [ForumPageSize + 1, ForumOffset(Page)]);
    try
      while not Q.EOF and (List.Count < ForumPageSize) do
      begin
        List.Add(TopicJSON(Q, Moderate(Me)));
        Q.Next;
      end;
      Result.Add('has_more', not Q.EOF);
    finally
      Q.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function PostPage(Id, PostId: integer; const Me: TMember): integer;
var
  Topic: TForumTopic;
  PostPosition: integer;
begin
  Topic := GetTopic(Me, Id, False);
  if PostId <= 0 then Refuse(404, 'Nothing here.');
  PostPosition := IntValue('SELECT p.' + ForumPositionColumn(Moderate(Me)) + ' FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id WHERE p.topic_id = :t AND p.id = :p' +
    ForumPostWhere(Moderate(Me)), [Topic.Id, PostId]);
  if PostPosition = 0 then Refuse(404, 'Nothing here.');
  Result := ForumPageForPosition(PostPosition);
end;

procedure ReadTopic(const Me: TMember; TopicId, PostId: integer);
var
  WasUnread, NowUnread: integer;
  Topic: TForumTopic;
begin
  if (Me.Id = 0) or (PostId = 0) then Exit;
  Exec('SET TRANSACTION ISOLATION LEVEL READ COMMITTED', []);
  Exec('START TRANSACTION', []);
  try
    Topic := LockTopic(Me, TopicId);
    EnsureBoardReads(Me, IntToStr(Topic.BoardId));
    WasUnread := IntValue('SELECT (' + UnreadWhere(Me.Id) + ') FROM forum_topics t WHERE t.id = :t', [TopicId]);
    Exec('INSERT INTO forum_topic_reads (user_id, topic_id, post_id) VALUES (:u, :t, :p)' + SqlOnConflict('user_id, topic_id', 'post_id = ' +
      SqlGreatest('post_id', SqlNew('post_id'))),
      [Me.Id, TopicId, PostId]);
    NowUnread := IntValue('SELECT (' + UnreadWhere(Me.Id) + ') FROM forum_topics t WHERE t.id = :t', [TopicId]);
    Exec('UPDATE forum_board_reads SET unread_count = ' + SqlGreatest('0', 'unread_count + :d') + ' WHERE user_id = :u AND board_id = :b',
      [NowUnread - WasUnread, Me.Id, Topic.BoardId]);
    Exec('COMMIT', []);
  except
    Exec('ROLLBACK', []);
    raise;
  end;
end;

function TopicPage(Id, Page: integer; const Me: TMember; PostId: integer): TJSONObject;
var
  Topic: TForumTopic;
  Q: TSQLQuery;
  List: TJSONArray;
  Item: TJSONObject;
  Hidden: boolean;
  PositionColumn: string;
  ReadPost: integer;
begin
  Topic := GetTopic(Me, Id, False);
  PositionColumn := 'visible_position';
  if Moderate(Me) then PositionColumn := 'position';
  if PostId > 0 then Page := PostPage(Id, PostId, Me);
  ReadPost := 0;
  Result := TJSONObject.Create(['page', Page, 'page_size', ForumPageSize]);
  try
    // One atomic increment for a topic opening; later pages do not write.
    if Page = 1 then
      Exec('UPDATE forum_topics SET view_count = view_count + 1 WHERE id = :t', [Topic.Id]);
    Q := Query(TopicSelect(Me) + ' WHERE t.id = :t', [Topic.Id]);
    try
      if Q.EOF then
        Refuse(404, 'Nothing here.');
      Result.Add('topic', TopicJSON(Q, Moderate(Me)));
    finally
      Q.Free;
    end;
    List := TJSONArray.Create;
    Result.Add('posts', List);
    Q := Query('SELECT p.*, COALESCE(a.name, '''') AS author_name, COALESCE(e.name, '''') AS editor_name,' +
      ' COALESCE(h.name, '''') AS hidden_name, a.avatar, a.roles, COALESCE(fm.post_count, 0) AS member_posts, ' + IsoTime('a.created') +
      ' AS joined, ' + IsoTime('p.created') + ' AS created_at, ' + IsoTime('p.edited') + ' AS edited_at, ' + IsoTime('p.hidden_at') +
      ' AS hidden_time' + ' FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id LEFT JOIN users a ON a.id = p.author_id' +
      ' LEFT JOIN forum_members fm ON fm.user_id = p.author_id LEFT JOIN users e ON e.id = p.editor_id LEFT JOIN users h ON h.id = p.hidden_by' +
      ' WHERE p.topic_id = :t' + ForumPostWhere(Moderate(Me)) + ' AND p.' + PositionColumn + ' > :o ORDER BY p.' + PositionColumn +
      ' LIMIT :n', [Topic.Id, ForumOffset(Page), ForumPageSize + 1]);
    try
      while not Q.EOF and (List.Count < ForumPageSize) do
      begin
        Hidden := Q.FieldByName('hidden').AsInteger <> 0;
        Item := TJSONObject.Create(['id', Q.FieldByName('id').AsInteger, 'author_id', Q.FieldByName('author_id').AsInteger, 'author',
          Q.FieldByName('author_name').AsString, 'created', Q.FieldByName('created_at').AsString, 'hidden', Hidden, 'number',
          Q.FieldByName(PositionColumn).AsInteger, 'avatar', AvatarUrl(Q.FieldByName('avatar').AsString), 'badge', Badge(Q.FieldByName('roles').AsString),
          'post_count', Q.FieldByName('member_posts').AsLargeInt, 'joined', Q.FieldByName('joined').AsString]);
        if not Hidden and (Q.FieldByName('id').AsInteger > ReadPost) then ReadPost := Q.FieldByName('id').AsInteger;
        List.Add(Item);
        if not Hidden or Moderate(Me) then
        begin
          Item.Add('body', Q.FieldByName('body').AsString);
          Item.Add('html', PostHtml(Q.FieldByName('body').AsString));
          Item.Add('edited', Q.FieldByName('edited_at').AsString);
          Item.Add('editor_id', Q.FieldByName('editor_id').AsInteger);
          Item.Add('editor', Q.FieldByName('editor_name').AsString);
        end;
        if Moderate(Me) then
        begin
          Item.Add('hidden_by', Q.FieldByName('hidden_by').AsInteger);
          Item.Add('hidden_name', Q.FieldByName('hidden_name').AsString);
          Item.Add('hidden_reason', Q.FieldByName('hidden_reason').AsString);
          Item.Add('hidden_at', Q.FieldByName('hidden_time').AsString);
        end;
        Q.Next;
      end;
      Result.Add('has_more', not Q.EOF);
    finally
      Q.Free;
    end;
    ReadTopic(Me, Topic.Id, ReadPost);
  except
    Result.Free;
    raise;
  end;
end;

{ ---- files with posts.  They are kept where the chat keeps its files
  (ChatFiles) and reached the same way, /f/token/name; the forum has its
  own limits, which the admin sets: the largest file and the kinds
  accepted.  A file belongs to the post whose text names it, and goes
  when the post does; one never put in a post goes after a day. }

const
  FORUM_FILE = 'forum';
  PICTURE_TYPES = ' png jpg jpeg gif webp ';
  DEFAULT_TYPES = 'png jpg jpeg gif webp zip txt log pas pp inc lpr lfm lpi lpk patch diff pdf';

function UploadMb: integer;
begin
  Result := SettingInt('forum_upload_mb', 5);
end;

{ The accepted kinds between blanks: " png jpg zip ". }
function UploadTypes: string;
var
  C: char;
begin
  Result := ' ';
  for C in LowerCase(Setting('forum_upload_types', DEFAULT_TYPES)) do
    if C in ['a'..'z', '0'..'9'] then
      Result := Result + C
    else if Result[Length(Result)] <> ' ' then
      Result := Result + ' ';
  if Result[Length(Result)] <> ' ' then
    Result := Result + ' ';
end;

function MayUpload(const Me: TMember): boolean;
begin
  Result := Writable(Me) and Can(Me, 'forum-upload') and (UploadMb > 0) and (Trim(UploadTypes) <> '');
end;

function ForumUploadAttributes(const Me: TMember): string;
begin
  if MayUpload(Me) then
    Result := ' data-upload-mb="' + IntToStr(UploadMb) + '" data-upload-types="' + Trim(UploadTypes) + '"'
  else
    Result := '';
end;

{ POST /api/forum/upload  file }
threadvar
  { the named lock an upload holds until its request is done }
  FileLock: string;

procedure FreeFileLock;
begin
  if FileLock <> '' then
  begin
    IntValue('SELECT ' + SqlUnlock(':n'), [FileLock]);
    FileLock := '';
  end;
end;

function TakeFile(Sent: TUploadedFile; const Me: TMember): TJSONObject; forward;

function UploadFile(R: TRequest; const Me: TMember): TJSONObject;
var
  Sent: TUploadedFile;
begin
  NeedWrite(Me);
  if not MayUpload(Me) then
    Refuse(403, 'Adding files to posts is not open to you here.');
  if R.Files.Count <> 1 then
    Refuse(400, 'Send one file at a time.');
  Sent := R.Files[0];
  if Sent.Size > int64(UploadMb) * 1024 * 1024 then
    Refuse(413, 'That file is too big for the forum.');
  // a member's uploads one after another: two at once would each find room
  // for itself in the same space
  if IntValue('SELECT ' + SqlLock(':n', 10), ['files-' + IntToStr(Me.Id)]) <> 1 then
    Refuse(409, 'Another of your files is still being taken in. Try again.');
  // let go by the request's handler once the file's row is saved for good
  FileLock := 'files-' + IntToStr(Me.Id);
  Result := TakeFile(Sent, Me);
end;

{ The file checked and kept; UploadFile holds the member's lock around it. }
function TakeFile(Sent: TUploadedFile; const Me: TMember): TJSONObject;
var
  Kind, Mime, Token, Name: string;
begin
  if IntValue('SELECT COALESCE(SUM(size), 0) FROM files WHERE user_id = :u', [Me.Id]) + Sent.Size > SettingInt('user_quota_mb', 500) * int64(1024 * 1024) then
    Refuse(413, 'Your files are at their limit. Delete some messages with files first.');
  Kind := LowerCase(ExtractFileExt(Sent.FileName));
  Delete(Kind, 1, 1);
  if (Kind = '') or (Pos(' ' + Kind + ' ', UploadTypes) = 0) then
    Refuse(415, 'That kind of file is not accepted here.');
  // a picture is one by its first bytes, whatever its name says
  Mime := ImageType(Sent.LocalFileName);
  if (Pos(' ' + Kind + ' ', PICTURE_TYPES) > 0) and (Mime = '') then
    Refuse(415, 'That file is not the picture its name says it is.');
  Token := StoreFile(Me.Id, FORUM_FILE, Sent.FileName, Sent.LocalFileName, 0, 0);
  Name := VarToStr(Value('SELECT name FROM files WHERE token = :t', [Token]));
  Result := TJSONObject.Create(['token', Token, 'name', Name, 'size', Sent.Size, 'image', Mime <> '', 'url', '/f/' + Token + '/' + Name]);
end;

{ The files a post's text names become the post's: /f/ and the 32 letters
  of a token.  Only the member's own, not yet in another post.  With
  DropOthers, a file the post had and its text no longer names is deleted:
  the post was changed and the file taken out. }
procedure KeepPostFiles(PostId, UserId: integer; const Body: string; DropOthers: boolean = False);
var
  P, I: integer;
  Token, Tokens: string;
  Good: boolean;
  Gone: TStringList;
begin
  Tokens := '';
  P := Pos('/f/', Body);
  while P > 0 do
  begin
    Token := Copy(Body, P + 3, 32);
    Good := (Length(Token) = 32) and (Copy(Body, P + 35, 1) = '/');
    for I := 1 to Length(Token) do
      if not (Token[I] in ['0'..'9', 'a'..'f']) then
        Good := False;
    if Good and (Pos(Token, Tokens) = 0) then
      Tokens := Tokens + Token + ',';
    P := Pos('/f/', Body, P + 3);
  end;
  if Tokens <> '' then
    AttachFiles(PostId, 0, UserId, Tokens, FORUM_FILE);
  if not DropOthers then
    Exit;
  Gone := TStringList.Create;
  try
    with Query('SELECT token FROM files WHERE message_id = :m AND purpose = :p', [PostId, FORUM_FILE]) do
    try
      while not EOF do
      begin
        if Pos(Fields[0].AsString, Tokens) = 0 then
          Gone.Add(Fields[0].AsString);
        Next;
      end;
    finally
      Free;
    end;
    for Token in Gone do
      DeleteFileByToken(Token);
  finally
    Gone.Free;
  end;
end;

function NewTopic(R: TRequest; const Me: TMember): TJSONObject;
var
  BoardId, TopicId, PostId: integer;
  Title, Body: string;
begin
  NeedWrite(Me);
  BoardId := Number(Field(R, 'board_id'));
  Title := Trim(Field(R, 'title'));
  Body := Field(R, 'body');
  CheckText(Title, 200, True);
  CheckText(Body, ForumMaxBody, False);
  LockBoard(BoardId);
  NeedBoard(Me, BoardId);
  Exec('INSERT INTO forum_topics (board_id, title, author_id, last_post_at, last_post_author)' + ' VALUES (:b, :t, :u, NOW(6), :a)', [BoardId, Title, Me.Id, Me.Id]);
  TopicId := IntValue('SELECT LAST_INSERT_ID()', []);
  Exec('INSERT INTO forum_posts (topic_id, author_id, body) VALUES (:t, :u, :b)', [TopicId, Me.Id, Body]);
  PostId := IntValue('SELECT LAST_INSERT_ID()', []);
  Exec('UPDATE forum_topics SET first_post_id = :p WHERE id = :t', [PostId, TopicId]);
  KeepPostFiles(PostId, Me.Id, Body);
  NotePost(TopicId, BoardId, Me.Id, PostId, True);
  Result := TJSONObject.Create(['topic_id', TopicId, 'post_id', PostId]);
end;

function Reply(R: TRequest; const Me: TMember): TJSONObject;
var
  Topic: TForumTopic;
  Body: string;
  PostId: integer;
begin
  NeedWrite(Me);
  Body := Field(R, 'body');
  CheckText(Body, ForumMaxBody, False);
  Topic := LockTopic(Me, Number(Field(R, 'topic_id')));
  if Topic.Hidden or (Topic.Locked and not Moderate(Me)) then
    Refuse(403, 'This topic is closed to replies.');
  Exec('INSERT INTO forum_posts (topic_id, author_id, body) VALUES (:t, :u, :b)', [Topic.Id, Me.Id, Body]);
  PostId := IntValue('SELECT LAST_INSERT_ID()', []);
  KeepPostFiles(PostId, Me.Id, Body);
  NotePost(Topic.Id, Topic.BoardId, Me.Id, PostId, False);
  Result := TJSONObject.Create(['topic_id', Topic.Id, 'post_id', PostId, 'page', (IntValue('SELECT p.' + ForumPositionColumn(Moderate(Me)) +
    ' FROM forum_posts p WHERE p.id = :p', [PostId]) - 1) div ForumPageSize + 1]);
end;

function Preview(R: TRequest; const Me: TMember): TJSONObject;
var
  Topic: TForumTopic;
  Body: string;
begin
  NeedWrite(Me);
  if Field(R, 'topic_id') <> '' then
  begin
    Topic := GetTopic(Me, Number(Field(R, 'topic_id')), False);
    if (Topic.Hidden or Topic.Locked) and not Moderate(Me) then
      Refuse(403, 'This topic is closed to replies.');
  end
  else
    NeedBoard(Me, Number(Field(R, 'board_id')));
  Body := Field(R, 'body');
  CheckText(Body, ForumMaxBody, False);
  Result := TJSONObject.Create(['html', PostHtml(Body)]);
end;

function ChangePost(R: TRequest; const Me: TMember; DeletePost: boolean): TJSONObject;
var
  Topic: TForumTopic;
  Id, TopicId, AuthorId: integer;
  Hidden, Allowed, HasReplies: boolean;
  Body, Title: string;
  Action: TForumDelete;
begin
  Action := fdRefuse;
  Id := Number(Field(R, 'id'));
  TopicId := IntValue('SELECT topic_id FROM forum_posts WHERE id = :p', [Id]);
  Topic := LockTopic(Me, TopicId);
  with Query('SELECT author_id, hidden FROM forum_posts WHERE id = :p AND topic_id = :t FOR UPDATE', [Id, Topic.Id]) do
  try
    if EOF then
      Refuse(404, 'Nothing here.');
    AuthorId := Fields[0].AsInteger;
    Hidden := Fields[1].AsInteger <> 0;
  finally
    Free;
  end;
  Allowed := ForumMayChange(Me.Id, AuthorId, Writable(Me), Moderate(Me), Topic.Locked, Hidden or Topic.Hidden);
  if not Allowed then
    Refuse(403, 'You cannot change this post.');
  if not DeletePost then
  begin
    Body := Field(R, 'body');
    CheckText(Body, ForumMaxBody, False);
    if R.ContentFields.IndexOfName('title') >= 0 then
    begin
      if Id <> Topic.FirstPostId then
        Refuse(400, 'Change the title with the first post.');
      Title := Trim(Field(R, 'title'));
      CheckText(Title, 200, True);
      Exec('UPDATE forum_topics SET title = :s WHERE id = :t', [Title, Topic.Id]);
    end;
    Exec('UPDATE forum_posts SET body = :b, edited = NOW(6), editor_id = :u WHERE id = :p', [Body, Me.Id, Id]);
    KeepPostFiles(Id, Me.Id, Body, True);
  end
  else
  begin
    HasReplies := IntValue('SELECT id FROM forum_posts WHERE topic_id = :t AND id <> :p LIMIT 1', [Topic.Id, Id]) > 0;
    Action := ForumDeleteAction(Allowed, Id = Topic.FirstPostId, HasReplies);
    case Action of
      fdPost:
      begin
        DeleteFilesOf(Id, FORUM_FILE);
        Exec('DELETE FROM forum_posts WHERE id = :p', [Id]);
      end;
      fdTopic:
      begin
        // the files of every post of the topic go with it
        with Query('SELECT id FROM forum_posts WHERE topic_id = :t', [Topic.Id]) do
        try
          while not EOF do
          begin
            DeleteFilesOf(Fields[0].AsInteger, FORUM_FILE);
            Next;
          end;
        finally
          Free;
        end;
        Exec('DELETE FROM forum_posts WHERE topic_id = :t', [Topic.Id]);
        Exec('DELETE FROM forum_topics WHERE id = :t', [Topic.Id]);
        Exec('DELETE FROM forum_topic_reads WHERE topic_id = :t', [Topic.Id]);
      end;
      fdHide: Exec('UPDATE forum_posts SET hidden = 1, hidden_by = :u, hidden_at = NOW(6),' + ' hidden_reason = :r WHERE id = :p', [Me.Id, 'author-delete', Id]);
      else
        Refuse(403, 'You cannot change this post.');
    end;
    if Action <> fdTopic then
      RefreshTopic(Topic.Id);
    RefreshPositions(Topic.Id);
    RefreshMember(AuthorId);
    RefreshBoard(Topic.BoardId);
  end;
  Result := TJSONObject.Create(['ok', True, 'topic_deleted', Action = fdTopic]);
end;

function ModerateTopic(R: TRequest; const Me: TMember): TJSONObject;
var
  Topic: TForumTopic;
  Id, Destination, Value: integer;
  Action, Reason: string;
begin
  if not Moderate(Me) then
    Refuse(403, 'You cannot moderate the forum.');
  Id := Number(Field(R, 'topic_id'));
  Action := Field(R, 'action');
  Destination := 0;
  if Action = 'move' then
    Destination := Number(Field(R, 'board_id'));
  Topic := LockTopic(Me, Id, Destination);
  if (Action = 'lock') or (Action = 'pin') then
  begin
    Value := Flag(R, 'value');
    if Action = 'lock' then
      Exec('UPDATE forum_topics SET locked = :v WHERE id = :t', [Value, Id])
    else
      Exec('UPDATE forum_topics SET pinned = :v WHERE id = :t', [Value, Id]);
  end
  else if Action = 'move' then
  begin
    NeedBoard(Me, Destination);
    if Destination <> Topic.BoardId then
    begin
      Exec('UPDATE forum_topics SET board_id = :b, moved_from = :o WHERE id = :t', [Destination, Topic.BoardId, Id]);
      RefreshBoard(Topic.BoardId);
      RefreshBoard(Destination);
    end;
  end
  else if (Action = 'hide') or (Action = 'unhide') then
  begin
    Reason := Field(R, 'reason');
    if Action = 'hide' then
      CheckText(Reason, 500, True);
    Exec('UPDATE forum_topics SET hidden = :v, hidden_by = :u, hidden_reason = :r, hidden_at = NOW(6) WHERE id = :t',
      [Ord(Action = 'hide'), Me.Id, Copy(Reason, 1, 500), Id]);
    RefreshBoard(Topic.BoardId);
    RefreshTopicMembers(Topic.Id);
  end
  else
    Refuse(400, 'Unknown moderation action.');
  Result := TJSONObject.Create(['ok', True]);
end;

function ModeratePost(R: TRequest; const Me: TMember): TJSONObject;
var
  Topic: TForumTopic;
  Id, TopicId: integer;
  Action, Reason: string;
begin
  if not Moderate(Me) then
    Refuse(403, 'You cannot moderate the forum.');
  Id := Number(Field(R, 'id'));
  TopicId := IntValue('SELECT topic_id FROM forum_posts WHERE id = :p', [Id]);
  Topic := LockTopic(Me, TopicId);
  if IntValue('SELECT id FROM forum_posts WHERE id = :p AND topic_id = :t', [Id, Topic.Id]) = 0 then
    Refuse(404, 'Nothing here.');
  Action := Field(R, 'action');
  if (Action <> 'hide') and (Action <> 'unhide') then
    Refuse(400, 'Unknown moderation action.');
  Reason := Field(R, 'reason');
  if Action = 'hide' then
    CheckText(Reason, 500, True);
  Exec('UPDATE forum_posts SET hidden = :v, hidden_by = :u, hidden_reason = :r, hidden_at = NOW(6) WHERE id = :p',
    [Ord(Action = 'hide'), Me.Id, Copy(Reason, 1, 500), Id]);
  RefreshTopic(Topic.Id);
  RefreshPositions(Topic.Id);
  RefreshTopicMembers(Topic.Id);
  RefreshBoard(Topic.BoardId);
  Result := TJSONObject.Create(['ok', True]);
end;

function Search(const Text: string; Page: integer; const Me: TMember): TJSONObject;
var
  Visible, HiddenPosts: string;
  Q: TSQLQuery;
  List: TJSONArray;
begin
  CheckText(Text, 100, True);
  Visible := ForumTopicWhere(ReadableBoards(Me), Moderate(Me));
  HiddenPosts := ' AND p.hidden = 0';
  if Moderate(Me) then
    HiddenPosts := '';
  Result := TJSONObject.Create(['page', Page, 'page_size', ForumPageSize]);
  try
    List := TJSONArray.Create;
    Result.Add('topics', List);
    Q := Query(TopicSelect(Me) + ' JOIN (SELECT topic_id, MAX(score) AS score FROM (' +
      ' SELECT id AS topic_id, MATCH(title) AGAINST(:q IN NATURAL LANGUAGE MODE) AS score FROM forum_topics' +
      ' WHERE MATCH(title) AGAINST(:q2 IN NATURAL LANGUAGE MODE)' +
      ' UNION ALL SELECT p.topic_id, MATCH(p.body) AGAINST(:q3 IN NATURAL LANGUAGE MODE) AS score FROM forum_posts p' +
      ' WHERE MATCH(p.body) AGAINST(:q4 IN NATURAL LANGUAGE MODE)' + HiddenPosts + ') hits GROUP BY topic_id) found ON found.topic_id = t.id WHERE ' +
      Visible + ' ORDER BY found.score DESC, t.id DESC LIMIT :n OFFSET :o', [Text, Text, Text, Text, ForumPageSize + 1, ForumOffset(Page)]);
    try
      while not Q.EOF and (List.Count < ForumPageSize) do
      begin
        List.Add(TopicJSON(Q, Moderate(Me)));
        Q.Next;
      end;
      Result.Add('has_more', not Q.EOF);
    finally
      Q.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure CheckPermissionName(const Name: string);
var
  C: char;
  List: TJSONArray;
  I: integer;
begin
  if (Name = '') or (Length(Name) > 40) then
    Refuse(400, 'Choose a read permission.');
  for C in Name do
    if not (C in ['a'..'z', '0'..'9', '-']) then
      Refuse(400, 'Choose a read permission.');
  List := PermissionsJSON;
  try
    for I := 0 to List.Count - 1 do
      if TJSONObject(List.Items[I]).Get('name', '') = Name then
        Exit;
  finally
    List.Free;
  end;
  Refuse(400, 'Choose a registered read permission.');
end;

function SaveBoard(R: TRequest): TJSONObject;
var
  Id, ParentId, Position, CategoryId: integer;
  Name, Slug, Description, Permission: string;
begin
  Id := OptionalNumber(R, 'id');
  ParentId := OptionalNumber(R, 'parent_id');
  if (Id < 0) or (ParentId < 0) then
    Refuse(400, 'Enter a valid number.');
  CategoryId := OptionalNumber(R, 'category_id');
  if (CategoryId < 0) or ((CategoryId > 0) and (IntValue('SELECT id FROM forum_categories WHERE id = :c', [CategoryId]) = 0)) then Refuse(400, 'Choose a category.');
  Position := OptionalNumber(R, 'position');
  Name := Trim(Field(R, 'name'));
  Description := Field(R, 'description');
  Permission := Field(R, 'read_permission');
  Slug := ForumSlug(Field(R, 'slug'));
  if (Slug = 'search') or (Slug = 't') or (Slug = 'recent') or (Slug = 'unread') then
    Refuse(400, 'That board slug is reserved.');
  if Slug = '' then
    Refuse(400, 'Enter a board slug using letters or numbers.');
  CheckText(Name, 100, True);
  if Description <> '' then
    CheckText(Description, 2000, False);
  CheckPermissionName(Permission);
  if Id > 0 then
    LockBoard(Id);
  if ParentId > 0 then
  begin
    if ParentId = Id then
      Refuse(400, 'A board cannot be its own parent.');
    with Query('SELECT parent_id FROM forum_boards WHERE id = :b', [ParentId]) do
    try
      if EOF or (Fields[0].AsInteger <> 0) then
        Refuse(400, 'Choose a top-level parent board.');
    finally
      Free;
    end;
    if IntValue('SELECT id FROM forum_boards WHERE parent_id = :b LIMIT 1', [Id]) > 0 then
      Refuse(400, 'A board with sub-boards must stay at the top level.');
  end;
  if IntValue('SELECT id FROM forum_boards WHERE slug = :s AND id <> :b LIMIT 1', [Slug, Id]) > 0 then
    Refuse(409, 'That board slug is already in use.');
  if Id = 0 then
  begin
    Exec('INSERT INTO forum_boards (name, slug, description, position, parent_id, read_permission, category_id)' + ' VALUES (:n, :s, :d, :p, NULLIF(:a, 0), :r, NULLIF(:c, 0))',
      [Name, Slug, Description, Position, ParentId, Permission, CategoryId]);
    Id := IntValue('SELECT LAST_INSERT_ID()', []);
  end
  else
    Exec('UPDATE forum_boards SET name = :n, slug = :s, description = :d, position = :p,' +
      ' parent_id = NULLIF(:a, 0), read_permission = :r, category_id = NULLIF(:c, 0) WHERE id = :b',
      [Name, Slug, Description, Position, ParentId, Permission, CategoryId, Id]);
  Result := TJSONObject.Create(['id', Id]);
end;

function RemoveBoard(R: TRequest): TJSONObject;
var
  Id: integer;
begin
  Id := Number(Field(R, 'id'));
  LockBoard(Id);
  if (IntValue('SELECT id FROM forum_boards WHERE parent_id = :b LIMIT 1', [Id]) > 0) or (IntValue('SELECT id FROM forum_topics WHERE board_id = :b LIMIT 1', [Id]) > 0) then
    Refuse(409, 'Move the topics and sub-boards before removing this board.');
  Exec('DELETE FROM forum_boards WHERE id = :b', [Id]);
  Exec('DELETE FROM forum_board_reads WHERE board_id = :b', [Id]);
  Result := TJSONObject.Create(['ok', True]);
end;

{ Ordering uses the same board update and accepts a position for each board. }
function OrderBoards(R: TRequest): TJSONObject;
var
  Entries: TStringArray;
  Entry: string;
  Id, I, J, Swap: integer;
  LockIds: array of integer;
  Seen: TStringList;
begin
  LockIds := nil;
  Entries := Field(R, 'ids').Split([',']);
  if (Length(Entries) = 0) or (Length(Entries) > 1000) then
    Refuse(400, 'Enter a list of board numbers.');
  Seen := TStringList.Create;
  try
    SetLength(LockIds, Length(Entries));
    for I := 0 to High(Entries) do
    begin
      Entry := Trim(Entries[I]);
      Id := Number(Entry);
      if Seen.IndexOf(IntToStr(Id)) >= 0 then
        Refuse(400, 'List each board once.');
      Seen.Add(IntToStr(Id));
      LockIds[I] := Id;
    end;
    for I := 1 to High(LockIds) do
    begin
      J := I;
      while (J > 0) and (LockIds[J] < LockIds[J - 1]) do
      begin
        Swap := LockIds[J];
        LockIds[J] := LockIds[J - 1];
        LockIds[J - 1] := Swap;
        Dec(J);
      end;
    end;
    for I := 0 to High(LockIds) do
      LockBoard(LockIds[I]);
    for I := 0 to Seen.Count - 1 do
      Exec('UPDATE forum_boards SET position = :p WHERE id = :b', [I, StrToInt(Seen[I])]);
  finally
    Seen.Free;
  end;
  Result := TJSONObject.Create(['ok', True]);
end;

function Categories: TJSONArray;
var
  Q: TSQLQuery;
begin
  Result := TJSONArray.Create;
  try
    Q := Query('SELECT id, name, position FROM forum_categories ORDER BY position, id', []);
    try
      while not Q.EOF do
      begin
        Result.Add(TJSONObject.Create(['id', Q.Fields[0].AsInteger, 'name', Q.Fields[1].AsString, 'position', Q.Fields[2].AsInteger]));
        Q.Next;
      end;
    finally
      Q.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function SaveCategory(R: TRequest): TJSONObject;
var
  CategoryId, CategoryPosition: integer;
  CategoryName: string;
begin
  CategoryId := OptionalNumber(R, 'id');
  CategoryPosition := OptionalNumber(R, 'position');
  CategoryName := Trim(Field(R, 'name'));
  CheckText(CategoryName, 100, True);
  if CategoryId < 0 then Refuse(400, 'Enter a valid number.');
  if CategoryId = 0 then
  begin
    Exec('INSERT INTO forum_categories (name, position) VALUES (:n, :p)', [CategoryName, CategoryPosition]);
    CategoryId := IntValue('SELECT LAST_INSERT_ID()', []);
  end
  else
  begin
    if IntValue('SELECT id FROM forum_categories WHERE id = :c', [CategoryId]) = 0 then Refuse(404, 'Nothing here.');
    Exec('UPDATE forum_categories SET name = :n, position = :p WHERE id = :c', [CategoryName, CategoryPosition, CategoryId]);
  end;
  Result := TJSONObject.Create(['id', CategoryId]);
end;

function RemoveCategory(R: TRequest): TJSONObject;
var
  CategoryId: integer;
begin
  CategoryId := Number(Field(R, 'id'));
  if IntValue('SELECT id FROM forum_categories WHERE id = :c', [CategoryId]) = 0 then Refuse(404, 'Nothing here.');
  if IntValue('SELECT id FROM forum_boards WHERE category_id = :c LIMIT 1', [CategoryId]) > 0 then Refuse(409, 'Move the boards before removing this category.');
  Exec('DELETE FROM forum_categories WHERE id = :c', [CategoryId]);
  Result := TJSONObject.Create(['ok', True]);
end;

function MarkRead(const Me: TMember): TJSONObject;
var
  Ids, Entry: string;
begin
  Ids := ReadableBoards(Me);
  if Ids <> '' then
  begin
    for Entry in Ids.Split([',']) do LockBoard(StrToInt(Entry));
    Exec('INSERT INTO forum_board_reads (user_id, board_id, read_at, unread_count) SELECT :u, id, NOW(6), 0 FROM forum_boards WHERE id IN (' +
      Ids + ')' + SqlOnConflict('user_id, board_id', 'read_at = ' + SqlNew('read_at') + ', unread_count = 0'), [Me.Id]);
  end;
  Result := TJSONObject.Create(['ok', True]);
end;

function Recent(Page: integer; const Me: TMember; Unread: boolean): TJSONObject;
var
  Q: TSQLQuery;
  Rows: TJSONArray;
  Predicate: string;
  Item: TJSONObject;
begin
  if Me.Id = 0 then Refuse(403, 'Sign in to read recent and unread posts.');
  Predicate := ForumTopicWhere(ReadableBoards(Me), False);
  Result := TJSONObject.Create(['page', Page]);
  try
    Rows := TJSONArray.Create;
    Result.Add('topics', Rows);
    if Unread then
      Q := Query(TopicSelect(Me) + ' WHERE ' + Predicate + ' AND ' + UnreadWhere(Me.Id) + ' ORDER BY t.last_post_at DESC, t.id DESC LIMIT :n OFFSET :o',
        [ForumPageSize + 1, ForumOffset(Page)])
    else
      Q := Query('SELECT p.id, p.topic_id, t.title, a.name, ' + IsoTime('p.created') +
        ' AS posted, p.body FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id LEFT JOIN users a ON a.id = p.author_id WHERE p.hidden = 0 AND ' +
        Predicate + ' ORDER BY p.created DESC, p.id DESC LIMIT :n OFFSET :o', [ForumPageSize + 1, ForumOffset(Page)]);
    try
      while not Q.EOF and (Rows.Count < ForumPageSize) do
      begin
        if Unread then Item := TopicJSON(Q, False)
        else
          Item := TJSONObject.Create(['id', Q.FieldByName('topic_id').AsInteger, 'title', Q.FieldByName('title').AsString, 'last_post_id',
            Q.FieldByName('id').AsInteger, 'last_post_at', Q.FieldByName('posted').AsString, 'last_post_name', Q.FieldByName('name').AsString,
            'html', PostHtml(Q.FieldByName('body').AsString)]);
        Rows.Add(Item);
        Q.Next;
      end;
      Result.Add('has_more', not Q.EOF);
    finally
      Q.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function ForumInfo(const Me: TMember): TJSONObject;
var
  Q: TSQLQuery;
  Rows: TJSONArray;
begin
  Result := TJSONObject.Create(['members', IntValue('SELECT members FROM forum_totals WHERE id = 1', [])]);
  try
    Result.Add('newest', VarToStr(Value('SELECT name FROM users ORDER BY id DESC LIMIT 1', [])));
    Rows := TJSONArray.Create;
    Result.Add('posts', Rows);
    Q := Query('SELECT p.id, p.topic_id, t.title, a.name, ' + IsoTime('p.created') +
      ' AS posted FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id LEFT JOIN users a ON a.id = p.author_id WHERE p.hidden = 0 AND ' +
      ForumTopicWhere(ReadableBoards(Me), False) + ' ORDER BY p.created DESC, p.id DESC LIMIT 5', []);
    try
      while not Q.EOF do
      begin
        Rows.Add(TJSONObject.Create(['id', Q.Fields[0].AsInteger, 'topic_id', Q.Fields[1].AsInteger, 'title', Q.Fields[2].AsString, 'author',
          Q.Fields[3].AsString, 'created', Q.Fields[4].AsString]));
        Q.Next;
      end;
    finally
      Q.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure Handle(R: TRequest; S: TResponse);
var
  Me: TMember;
  Path: string;
  Data: TJSONData;
  Answer: TJSONData;
  Transaction, StructureLock, Admin: boolean;
begin
  Transaction := False;
  StructureLock := False;
  Data := nil;
  S.SetCustomHeader('Cache-Control', 'private, no-store');
  try
    CheckConnection;
    if not ForumOn then
      Refuse(404, 'Nothing here.');
    Path := LowerCase(ExcludeTrailingPathDelimiter(HTTPDecode(R.PathInfo)));
    Admin := Path.StartsWith('/api/forum/admin/');
    if Admin then
    begin
      if not NeedPermission(R, S, 'forum-boards', Me) then
        Exit;
    end
    else
    begin
      Me := CurrentMember(R);
      if not Can(Me, 'forum-read') then
        Refuse(404, 'Nothing here.');
    end;
    if R.Method = 'POST' then
    begin
      if FromAnotherSite(R) then
        Refuse(403, 'Send this form from this site.');
      if (Me.Id = 0) or Me.Banned then
        Refuse(403, 'Sign in to change the forum.');
      if Admin then
      begin
        if IntValue('SELECT ' + SqlLock('''forum-boards''', 5), []) <> 1 then
          Refuse(409, 'The boards are being changed. Try again.');
        StructureLock := True;
      end;
      Exec('SET TRANSACTION ISOLATION LEVEL READ COMMITTED', []);
      Exec('START TRANSACTION', []);
      Transaction := True;
      case Path of
        '/api/forum/read': Data := MarkRead(Me);
        '/api/forum/admin/category': Data := SaveCategory(R);
        '/api/forum/admin/category/remove': Data := RemoveCategory(R);
        '/api/forum/preview': Data := Preview(R, Me);
        '/api/forum/upload': Data := UploadFile(R, Me);
        '/api/forum/topic/new': Data := NewTopic(R, Me);
        '/api/forum/reply': Data := Reply(R, Me);
        '/api/forum/post/edit': Data := ChangePost(R, Me, False);
        '/api/forum/post/delete': Data := ChangePost(R, Me, True);
        '/api/forum/topic/moderate': Data := ModerateTopic(R, Me);
        '/api/forum/post/moderate': Data := ModeratePost(R, Me);
        '/api/forum/admin/board': Data := SaveBoard(R);
        '/api/forum/admin/order': Data := OrderBoards(R);
        '/api/forum/admin/remove': Data := RemoveBoard(R);
        else
          Refuse(404, 'Nothing here.');
      end;
      Exec('COMMIT', []);
      Transaction := False;
      FreeFileLock;
    end
    else
      case Path of
        '/api/forum/recent': Data := Recent(ForumPage(R.QueryFields.Values['page']), Me, False);
        '/api/forum/unread': Data := Recent(ForumPage(R.QueryFields.Values['page']), Me, True);
        '/api/forum/admin/categories': Data := Categories;
        '/api/forum/boards': Data := Boards(Me, False);
        '/api/forum/board': Data := BoardPage(Number(R.QueryFields.Values['id']), ForumPage(R.QueryFields.Values['page']), Me);
        '/api/forum/topic': Data := TopicPage(Number(R.QueryFields.Values['id']), ForumPage(R.QueryFields.Values['page']), Me, StrToIntDef(R.QueryFields.Values['post'], 0));
        '/api/forum/search': Data := Search(Trim(R.QueryFields.Values['q']), ForumPage(R.QueryFields.Values['page']), Me);
        '/api/forum/admin/boards': Data := Boards(Me, True);
        else
          Refuse(404, 'Nothing here.');
      end;
    if StructureLock then
    begin
      IntValue('SELECT ' + SqlUnlock('''forum-boards'''), []);
      StructureLock := False;
    end;
    Answer := Data;
    Data := nil;
    SendJSON(S, Answer);
  except
    on E: Exception do
    begin
      Data.Free;
      if Transaction then
        Exec('ROLLBACK', []);
      FreeFileLock;
      if StructureLock then
        IntValue('SELECT ' + SqlUnlock('''forum-boards'''), []);
      if E is EForumRequest then
        SendText(S, EForumRequest(E).Code, Say(E.Message))
      else
        raise;
    end;
  end;
end;

procedure AddRoute(const Path: string; Method: TRouteMethod; Admin: boolean = False);
begin
  HTTPRouter.RegisterRoute('/api/forum/' + Path, Method, @Handle);
  if Admin then
    RegisterAdminRoute('/api/forum/' + Path, 'forum-boards');
end;

initialization
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_boards (' + ' id INT AUTO_INCREMENT PRIMARY KEY, old_id BIGINT NULL UNIQUE,' +
    ' name VARCHAR(100) NOT NULL, slug VARCHAR(80) NOT NULL UNIQUE, description TEXT NOT NULL,' +
    ' position INT NOT NULL DEFAULT 0, parent_id INT NULL, read_permission VARCHAR(40) NOT NULL DEFAULT ''forum-read'',' +
    ' topic_count BIGINT NOT NULL DEFAULT 0, post_count BIGINT NOT NULL DEFAULT 0,' + ' last_post_at DATETIME(6) NULL, last_post_author INT NULL,' +
    ' INDEX (parent_id, position, id)) ENGINE=InnoDB CHARACTER SET utf8mb4');
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_topics (' + ' id INT AUTO_INCREMENT PRIMARY KEY, old_id BIGINT NULL UNIQUE, board_id INT NOT NULL,' +
    ' title VARCHAR(200) NOT NULL, author_id INT NOT NULL, created DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),' +
    ' first_post_id INT NULL, last_post_at DATETIME(6) NOT NULL, last_post_author INT NOT NULL,' +
    ' reply_count BIGINT NOT NULL DEFAULT 0, view_count BIGINT NOT NULL DEFAULT 0,' +
    ' pinned TINYINT NOT NULL DEFAULT 0, locked TINYINT NOT NULL DEFAULT 0, hidden TINYINT NOT NULL DEFAULT 0,' +
    ' moved_from INT NULL, hidden_by INT NULL, hidden_reason VARCHAR(500) NULL, hidden_at DATETIME(6) NULL,' +
    ' INDEX (board_id, pinned, last_post_at, id), INDEX (board_id, hidden, last_post_at, id),' + ' FULLTEXT INDEX forum_titles (title)) ENGINE=InnoDB CHARACTER SET utf8mb4');
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_posts (' + ' id INT AUTO_INCREMENT PRIMARY KEY, old_id BIGINT NULL UNIQUE, topic_id INT NOT NULL, author_id INT NOT NULL,' +
    ' body MEDIUMTEXT NOT NULL, created DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),' + ' edited DATETIME(6) NULL, editor_id INT NULL, hidden TINYINT NOT NULL DEFAULT 0,' +
    ' hidden_by INT NULL, hidden_reason VARCHAR(500) NULL, hidden_at DATETIME(6) NULL,' + ' INDEX (topic_id, created, id), INDEX (topic_id, hidden, created, id),' +
    ' FULLTEXT INDEX forum_bodies (body)) ENGINE=InnoDB CHARACTER SET utf8mb4');
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_categories (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL, position INT NOT NULL DEFAULT 0, old_id BIGINT NULL UNIQUE) ENGINE=InnoDB CHARACTER SET utf8mb4');
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_members (user_id INT PRIMARY KEY, post_count BIGINT NOT NULL DEFAULT 0) ENGINE=InnoDB');
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_totals (id INT PRIMARY KEY, members BIGINT NOT NULL DEFAULT 0) ENGINE=InnoDB');
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_board_reads (user_id INT NOT NULL, board_id INT NOT NULL, read_at DATETIME(6) NOT NULL, unread_count BIGINT NOT NULL DEFAULT 0, PRIMARY KEY(user_id, board_id), INDEX(board_id, user_id)) ENGINE=InnoDB');
  RegisterTable('CREATE TABLE IF NOT EXISTS forum_topic_reads (user_id INT NOT NULL, topic_id INT NOT NULL, post_id INT NOT NULL, PRIMARY KEY(user_id, topic_id)) ENGINE=InnoDB');
  RegisterUpgrade('forum-categories',
    'ALTER TABLE forum_boards ADD category_id INT NULL, ADD last_topic_id INT NULL, ADD unread_topic_count BIGINT NOT NULL DEFAULT 0, ADD total_topic_count BIGINT NOT NULL DEFAULT 0, ADD INDEX (category_id, position, id)');
  RegisterUpgrade('forum-post-positions',
    'ALTER TABLE forum_posts ADD position INT NOT NULL DEFAULT 0, ADD visible_position INT NOT NULL DEFAULT 0, ADD INDEX (topic_id, position), ADD INDEX (topic_id, visible_position), ADD INDEX (hidden, created, id), ADD INDEX (author_id, topic_id)');
  RegisterUpgrade('forum-topic-totals',
    'ALTER TABLE forum_topics ADD last_post_id INT NULL, ADD post_count INT NOT NULL DEFAULT 0, ADD display_count INT NOT NULL DEFAULT 0, ADD INDEX (hidden, last_post_at, id)');
  RegisterUpgrade('forum-position-fill',
    'UPDATE forum_posts p JOIN (SELECT p2.id, ROW_NUMBER() OVER (PARTITION BY p2.topic_id ORDER BY p2.created, p2.id) AS ordinal, SUM(CASE WHEN p2.hidden = 0 OR p2.id = t.first_post_id THEN 1 ELSE 0 END) OVER (PARTITION BY p2.topic_id ORDER BY p2.created, p2.id) AS visible_ordinal FROM forum_posts p2 JOIN forum_topics t ON t.id = p2.topic_id) ranks ON ranks.id = p.id SET p.position = ranks.ordinal, p.visible_position = ranks.visible_ordinal');
  RegisterUpgrade('forum-topic-totals-fill',
    'UPDATE forum_topics t SET last_post_id = (SELECT p.id FROM forum_posts p WHERE p.topic_id = t.id AND p.hidden = 0 ORDER BY p.created DESC, p.id DESC LIMIT 1), post_count = COALESCE((SELECT MAX(p.position) FROM forum_posts p WHERE p.topic_id = t.id), 0), display_count = COALESCE((SELECT MAX(p.visible_position) FROM forum_posts p WHERE p.topic_id = t.id), 0)');
  RegisterUpgrade('forum-board-last-fill',
    'UPDATE forum_boards b SET total_topic_count = (SELECT COUNT(*) FROM forum_topics t WHERE t.board_id = b.id), unread_topic_count = (SELECT COUNT(*) FROM forum_topics t WHERE t.board_id = b.id AND t.hidden = 0 AND t.last_post_id IS NOT NULL), last_topic_id = (SELECT t.id FROM forum_topics t WHERE t.board_id = b.id AND t.hidden = 0 AND t.last_post_id IS NOT NULL ORDER BY t.last_post_at DESC, t.id DESC LIMIT 1)');
  RegisterUpgrade('forum-board-last-visible-fill',
    'UPDATE forum_boards SET last_post_at = (SELECT t.last_post_at FROM forum_topics t WHERE t.id = forum_boards.last_topic_id),' +
    ' last_post_author = (SELECT t.last_post_author FROM forum_topics t WHERE t.id = forum_boards.last_topic_id)');
  RegisterUpgrade('forum-member-fill',
    'INSERT INTO forum_members (user_id, post_count) SELECT u.id, (SELECT COUNT(*) FROM forum_posts p JOIN forum_topics t ON t.id = p.topic_id WHERE p.author_id = u.id AND p.hidden = 0 AND t.hidden = 0) FROM users u');
  RegisterUpgrade('forum-member-total-fill', 'INSERT INTO forum_totals (id, members) SELECT 1, COUNT(*) FROM users');
  RegisterNewMemberHook(@NewForumMember);
  RegisterPermission('forum-read', 'Read the forum', 'guest,member');
  RegisterPermission('forum-post', 'Post in the forum', 'member');
  RegisterPermission('forum-moderate', 'Moderate the forum', 'moderator,admin');
  RegisterPermission('forum-boards', 'Manage forum boards', 'admin');
  RegisterPermission('forum-members', 'Read member forum boards', 'member');
  RegisterPermission('forum-staff', 'Read staff forum boards', 'moderator,admin');
  RegisterAdminSection('forum', 'Forum boards', 'forum-boards');
  RegisterBodyLimit('/api/forum/*', 196608);
  // a file is as large as the admin's limit lets it be, up to what one request carries
  RegisterBodyLimit('/api/forum/upload', 32 * 1024 * 1024);
  RegisterPermission('forum-upload', 'Add files to forum posts', 'member');
  RegisterSetting('forum_upload_mb', 'Largest file in a forum post, in MB (0: no files; 32 MB at most)', '5', 'number', 'Forum');
  RegisterSetting('forum_upload_types', 'Kinds of file accepted in forum posts (endings, between blanks)', DEFAULT_TYPES, 'text', 'Forum');
  RegisterRequestLimit('forumpost', 'Forum posts', 60, 20, 10);
  LimitRoute('forumpost', '/api/forum/topic/new', 'POST');
  LimitRoute('forumpost', '/api/forum/reply', 'POST');
  RegisterRequestLimit('forumedit', 'Forum changes', 180, 60, 10);
  LimitRoute('forumedit', '/api/forum/post/*', 'POST');
  LimitRoute('forumedit', '/api/forum/topic/moderate', 'POST');
  LimitRoute('forumedit', '/api/forum/preview', 'POST');
  LimitRoute('forumedit', '/api/forum/upload', 'POST');
  LimitRoute('forumedit', '/api/forum/read', 'POST');
  RegisterSearchRoute('/api/forum/search');
  AddRoute('read', rmPost);
  AddRoute('recent', rmGet);
  AddRoute('unread', rmGet);
  AddRoute('admin/categories', rmGet, True);
  AddRoute('admin/category', rmPost, True);
  AddRoute('admin/category/remove', rmPost, True);
  AddRoute('boards', rmGet);
  AddRoute('board', rmGet);
  AddRoute('topic', rmGet);
  AddRoute('search', rmGet);
  AddRoute('preview', rmPost);
  AddRoute('upload', rmPost);
  AddRoute('topic/new', rmPost);
  AddRoute('reply', rmPost);
  AddRoute('post/edit', rmPost);
  AddRoute('post/delete', rmPost);
  AddRoute('topic/moderate', rmPost);
  AddRoute('post/moderate', rmPost);
  AddRoute('admin/boards', rmGet, True);
  AddRoute('admin/board', rmPost, True);
  AddRoute('admin/order', rmPost, True);
  AddRoute('admin/remove', rmPost, True);
  RegisterForumPages;
end.
