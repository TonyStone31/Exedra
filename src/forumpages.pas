unit ForumPages;

{$mode objfpc}{$H+}

interface

uses fpjson, ChatUsers;

function ForumBoardTree(List: TJSONArray; ParentId: integer): string;
function ForumTopicsHtml(List: TJSONArray): string;
function ForumRecentHtml(List: TJSONArray): string;
function ForumPostsHtml(Data: TJSONObject; const Me: TMember): string;
function ForumPager(const Path: string; Page: integer; More: boolean; const SearchText: string = ''; TotalPages: integer = 0): string;
procedure RegisterForumPages;

implementation

uses
  Classes, SysUtils, Variants, httpdefs, httproute, ChatDb,
  ChatRoles, ChatGuard, ChatStats, ChatVisitors, SiteWords, WebPages,
  Forum, ForumSwitch, ForumRules;

function W(const Text: string): string;
begin
  Result := E(Say(Text));
end;

function Link(const Address, Caption: string): string;
begin
  Result := '<a href="' + E(Address) + '">' + E(Caption) + '</a>';
end;

function HiddenField(const Key, Text: string): string;
begin
  Result := '<input type="hidden" name="' + E(Key) + '" value="' + E(Text) + '">';
end;

function Input(const Key, Caption, Text: string; Limit: integer): string;
begin
  Result := '<label>' + E(Caption) + '<input name="' + E(Key) + '" value="' + E(Text) + '" maxlength="' + IntToStr(Limit) + '" required></label>';
end;

function Button(const Caption: string): string;
begin
  Result := '<button>' + E(Caption) + '</button>';
end;

function Form(const Action, Fields, Caption: string): string;
begin
  Result := '<form method="post" action="/api/forum/' + Action + '" data-forum-form>' + Fields + Button(Caption) + '<p class="forum-error" role="alert"></p></form>';
end;

{ The post box; Upload is what ForumUploadAttributes gave for the member. }
function Editor(const Body, Upload: string): string;
begin
  Result := '<label>' + W('Post') + '<textarea class="forum-editor" name="body" rows="10" maxlength="' + IntToStr(ForumMaxBody) + '"' +
    Upload + ' required>' + E(Body) + '</textarea></label>';
end;

function ForumPager(const Path: string; Page: integer; More: boolean; const SearchText: string; TotalPages: integer): string;
var
  I, FirstPage, LastPage: integer;
begin
  Result := '<nav class="forum-pages" aria-label="' + W('Pages') + '"><span>' + W('Pages') + ':</span> ';
  if Page > 1 then
    Result := Result + Link(ForumPageUrl(Path, Page - 1, SearchText), Say('Previous')) + ' ';
  FirstPage := Page - 2;
  if FirstPage < 1 then FirstPage := 1;
  LastPage := Page + 2;
  if LastPage > TotalPages then LastPage := TotalPages;
  if (TotalPages > 1) and (FirstPage > 1) then Result := Result + Link(ForumPageUrl(Path, 1, SearchText), '1') + ' … ';
  if TotalPages > 1 then
    for I := FirstPage to LastPage do
      if I <> Page then Result := Result + Link(ForumPageUrl(Path, I, SearchText), IntToStr(I)) + ' '
      else
        Result := Result + '<strong aria-current="page">' + IntToStr(Page) + '</strong> ';
  if (TotalPages > 1) and (LastPage < TotalPages) then Result := Result + ' … ' + Link(ForumPageUrl(Path, TotalPages, SearchText), IntToStr(TotalPages));
  if TotalPages <= 1 then Result := Result + '<strong aria-current="page">' + IntToStr(Page) + '</strong>';
  if More then
    Result := Result + ' ' + Link(ForumPageUrl(Path, Page + 1, SearchText), Say('Next'));
  Result := Result + '</nav>';
end;

function PageJump(Down: boolean): string;
begin
  if Down then
    Result := '<a class="forum-jump" href="#forum-bottom">' + W('Go down') + '</a>'
  else
    Result := '<a class="forum-jump" href="#forum-top">' + W('Go up') + '</a>';
end;

function MemberLink(const Name: string): string;
begin
  Result := Link('/u/' + HTTPEncode(Name), Name);
end;

function StatusIcon(const Caption, Kind: string; Unread: boolean): string;
var
  Css, Shape: string;
begin
  Css := 'forum-status';
  if Unread then Css := Css + ' unread';
  Shape := 'M3 3h14v11H9l-5 3v-3H3z';
  if Kind <> 'posts' then Css := 'forum-symbol forum-' + Kind;
  case Kind of
    'locked': Shape := 'M5 9h10v8H5z M7 9V6a3 3 0 0 1 6 0v3 M10 12v2';
    'pinned': Shape := 'M6 3h8l-1 5 3 3H4l3-3z M10 11v7';
    'hot': Shape := 'M11 2c1 5 5 5 5 10a6 6 0 0 1-12 0c0-3 2-5 3-6 0 3 1 4 2 4 2-2 2-5 2-8z';
  end;
  Result := '<span class="' + Css + '" role="img" aria-label="' + E(Caption) + '" title="' + E(Caption) + '"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="' +
    Shape + '"></path></svg></span>';
end;

function LastPost(Item: TJSONObject; BoardIndex: boolean): string;
var
  TopicId: integer;
  Address, Posted: string;
begin
  Result := '<span class="forum-last">' + W('No posts yet.') + '</span>';
  if (Item.Get('last_post_at', '') = '') or (Item.Get('last_post_id', 0) <= 0) then Exit;
  TopicId := Item.Get('last_topic_id', Item.Get('id', 0));
  Address := ForumPostUrl(TopicId, Item.Get('last_post_id', 0));
  Posted := DateTag(Item.Get('last_post_at', ''), True);
  if BoardIndex then
    Result := Format(W('Last post by %s in %s on %s'), [MemberLink(Item.Get('last_post_name', '')), Link(Address, Item.Get('last_title', Say('Last post'))), Posted])
  else
    Result := Format(W('%s by %s'), ['<a href="' + E(Address) + '">' + Posted + '</a>', MemberLink(Item.Get('last_post_name', ''))]);
  Result := '<div class="forum-last">' + Result + '</div>';
end;

function BoardRow(Item: TJSONObject; List: TJSONArray): string;
var
  I: integer;
  Child: TJSONObject;
  Children, Caption: string;
begin
  Children := '';
  for I := 0 to List.Count - 1 do
  begin
    Child := TJSONObject(List[I]);
    if Child.Get('parent_id', 0) <> Item.Get('id', 0) then Continue;
    if Children <> '' then Children := Children + ', ';
    Children := Children + Link(ForumBoardUrl(Child.Get('slug', '')), Child.Get('name', ''));
    if Child.Get('unread', False) then Children := Children + ' ' + StatusIcon(Say('New posts'), 'posts', True);
  end;
  if Children <> '' then Children := '<p class="forum-children">' + W('Child boards') + ': ' + Children + '</p>';
  Caption := Say('No new posts');
  if Item.Get('unread', False) then Caption := Say('New posts');
  Result := '<li class="forum-board-row">' + StatusIcon(Caption, 'posts', Item.Get('unread', False)) + '<div><h3>' +
    Link(ForumBoardUrl(Item.Get('slug', '')), Item.Get('name', '')) + '</h3><p class="forum-description">' + E(Item.Get('description', '')) +
    '</p>' + Children + '</div><div class="forum-counts">' + E(SayCount(Item.Get('post_count', 0), '%d post', '%d posts')) + '<br>' +
    E(SayCount(Item.Get('topic_count', 0), '%d topic', '%d topics')) + '</div>' + LastPost(Item, True) + '</li>';
end;

function ForumBoardTree(List: TJSONArray; ParentId: integer): string;
var
  I, J, CategoryId: integer;
  Item: TJSONObject;
  Groups: TStringList;
  Rows, Caption: string;
begin
  Result := '';
  Groups := TStringList.Create;
  try
    for I := 0 to List.Count - 1 do
    begin
      Item := TJSONObject(List[I]);
      if Item.Get('parent_id', 0) <> ParentId then Continue;
      CategoryId := Item.Get('category_id', 0);
      if Groups.IndexOf(IntToStr(CategoryId)) < 0 then Groups.Add(IntToStr(CategoryId));
    end;
    for J := 0 to Groups.Count - 1 do
    begin
      CategoryId := StrToInt(Groups[J]);
      Rows := '';
      Caption := Say('General');
      for I := 0 to List.Count - 1 do
      begin
        Item := TJSONObject(List[I]);
        if (Item.Get('parent_id', 0) <> ParentId) or (Item.Get('category_id', 0) <> CategoryId) then Continue;
        if Item.Get('category', '') <> '' then Caption := Item.Get('category', '');
        Rows := Rows + BoardRow(Item, List);
      end;
      Result := Result + '<section class="forum-category" id="category-' + IntToStr(CategoryId) + '"><h2>' + E(Caption) + '</h2><ul class="forum-boards">' +
        Rows + '</ul></section>';
    end;
  finally
    Groups.Free;
  end;
end;

function Marks(Item: TJSONObject): string;
begin
  Result := '';
  if Item.Get('pinned', False) then
    Result := Result + ' ' + StatusIcon(Say('Pinned'), 'pinned', False);
  if Item.Get('locked', False) then
    Result := Result + ' ' + StatusIcon(Say('Locked'), 'locked', False);
  if Item.Get('reply_count', 0) >= 20 then
    Result := Result + ' ' + StatusIcon(Say('Hot topic'), 'hot', False);
  if Item.Get('hidden', False) then
    Result := Result + ' <span class="forum-mark">' + W('Hidden') + '</span>';
end;

function ForumTopicsHtml(List: TJSONArray): string;
var
  I: integer;
  Item: TJSONObject;
  Caption: string;
begin
  Result := '';
  for I := 0 to List.Count - 1 do
  begin
    Item := TJSONObject(List[I]);
    Caption := Say('No new posts');
    if Item.Get('unread', False) then Caption := Say('New posts');
    Result := Result + '<tr><td>' + StatusIcon(Caption, 'posts', Item.Get('unread', False)) + '</td><td><h3>' +
      Link(ForumTopicUrl(Item.Get('id', 0)), Item.Get('title', '')) + Marks(Item) + '</h3><p class="forum-started">' + W('Started by') +
      ' ' + MemberLink(Item.Get('author', '')) + ' · ' + DateTag(Item.Get('created', ''), True) + '</p>';
    Result := Result + '</td><td class="forum-counts">' + E(SayCount(Item.Get('reply_count', 0), '%d reply', '%d replies')) + '<br>' +
      E(SayCount(Item.Get('view_count', 0), '%d view', '%d views')) + '</td><td>' + LastPost(Item, False) + '</td></tr>';
  end;
  if Result = '' then Result := '<p>' + W('No topics found.') + '</p>'
  else
    Result := '<table class="forum-topics"><thead><tr><th><span class="sr-only">' + W('Status') + '</span></th><th>' + W('Subject') +
      '</th><th>' + W('Replies / Views') + '</th><th>' + W('Last post') + '</th></tr></thead><tbody>' + Result + '</tbody></table>';
end;

function ForumRecentHtml(List: TJSONArray): string;
var
  I: integer;
  Item: TJSONObject;
begin
  Result := '';
  for I := 0 to List.Count - 1 do
  begin
    Item := TJSONObject(List[I]);
    Result := Result + '<article class="forum-recent"><header><h2>' + Link(ForumPostUrl(Item.Get('id', 0), Item.Get('last_post_id', 0)),
      Item.Get('title', '')) + '</h2>' + MemberLink(Item.Get('last_post_name', '')) + ' · ' + DateTag(Item.Get('last_post_at', ''), True) + '</header>';
    // Only the forum's server renderer supplies HTML in this stream.
    Result := Result + '<div class="forum-body body">' + Item.Get('html', '') + '</div></article>';
  end;
  if Result = '' then Result := '<p>' + W('No posts found.') + '</p>';
end;

function HideDetails(Item: TJSONObject): string;
begin
  Result := '';
  if Item.Get('hidden_at', '') <> '' then
    Result := '<p class="forum-hidden">' + W('Moderation') + ': ' + E(Item.Get('hidden_name', '')) + ' · ' + DateTag(Item.Get('hidden_at', ''), True) +
      ' · ' + E(Item.Get('hidden_reason', '')) + '</p>';
end;

function HideForm(const Kind, Key: string; Id: integer; IsHidden: boolean): string;
var
  Action, Caption, Fields: string;
begin
  Action := 'hide';
  Caption := Say('Hide');
  Fields := '';
  if IsHidden then
  begin
    Action := 'unhide';
    Caption := Say('Restore');
  end
  else
    Fields := Input('reason', Say('Reason'), '', 500);
  Result := Form(Kind + '/moderate', HiddenField(Key, IntToStr(Id)) + HiddenField('action', Action) + Fields, Caption);
end;

function TopicTools(Topic: TJSONObject; List: TJSONArray): string;
var
  Ids, Options, LockCaption, PinCaption: string;
  I: integer;
  Board: TJSONObject;
begin
  Ids := HiddenField('topic_id', IntToStr(Topic.Get('id', 0)));
  LockCaption := Say('Lock');
  PinCaption := Say('Pin');
  if Topic.Get('locked', False) then
    LockCaption := Say('Unlock');
  if Topic.Get('pinned', False) then
    PinCaption := Say('Unpin');
  Result := '<details data-forum-tools hidden><summary>' + W('Moderate topic') + '</summary>' + Form('topic/moderate', Ids +
    HiddenField('action', 'lock') + HiddenField('value', IntToStr(Ord(not Topic.Get('locked', False)))), LockCaption) +
    Form('topic/moderate', Ids + HiddenField('action', 'pin') + HiddenField('value', IntToStr(Ord(not Topic.Get('pinned', False)))), PinCaption) +
    HideForm('topic', 'topic_id', Topic.Get('id', 0), Topic.Get('hidden', False));
  Options := '';
  for I := 0 to List.Count - 1 do
  begin
    Board := TJSONObject(List[I]);
    if Board.Get('id', 0) = Topic.Get('board_id', 0) then
      Continue;
    Options := Options + '<option value="' + IntToStr(Board.Get('id', 0)) + '">' + E(Board.Get('name', '')) + '</option>';
  end;
  if Options <> '' then
    Result := Result + Form('topic/moderate', Ids + HiddenField('action', 'move') + '<label>' + W('Destination board') +
      '<select name="board_id" required>' + Options + '</select></label>', Say('Move'));
  Result := Result + '</details>';
end;

function PostAction(const PanelId, Caption: string): string;
begin
  Result := '<button type="button" data-forum-panel="' + PanelId + '" aria-controls="' + PanelId + '" aria-expanded="false">' + E(Caption) + '</button>';
end;

function ActionPanel(const PanelId, Content: string): string;
begin
  Result := '<div class="forum-action-panel" id="' + PanelId + '" hidden>' + Content + '</div>';
end;

function MemberAvatar(const MemberName, Address: string): string;
var
  Hue, InitialBytes: integer;
  C: char;
  Initial: string;
begin
  if Address <> '' then
    Exit('<img class="forum-avatar" src="' + E(Address) + '" alt="" loading="lazy">');
  Hue := 0;
  for C in LowerCase(MemberName) do Hue := (Hue * 31 + Ord(C)) mod 360;
  InitialBytes := 1;
  while (InitialBytes < Length(MemberName)) and ((Ord(MemberName[InitialBytes + 1]) and $C0) = $80) do Inc(InitialBytes);
  Initial := UpperCase(Copy(MemberName, 1, InitialBytes));
  if Initial = '' then Initial := '?';
  Result := '<span class="forum-avatar forum-avatar-placeholder" aria-hidden="true" style="--forum-hue:' + IntToStr(Hue) + '">' + E(Initial) + '</span>';
end;

function ForumPostsHtml(Data: TJSONObject; const Me: TMember): string;
var
  Topic, Item: TJSONObject;
  List: TJSONArray;
  I: integer;
  Fields, Subject, BadgeCaption, Actions, Panels, PanelId, Caption: string;
  MayChange: boolean;
begin
  Result := '';
  Topic := Data.Objects['topic'];
  List := Data.Arrays['posts'];
  for I := 0 to List.Count - 1 do
  begin
    Item := TJSONObject(List[I]);
    Subject := Topic.Get('title', '');
    if Item.Get('id', 0) <> Topic.Get('first_post_id', 0) then Subject := Say('Re:') + ' ' + Subject;
    Result := Result + '<article class="forum-post" id="post-' + IntToStr(Item.Get('id', 0)) + '"><aside class="forum-poster">';
    Result := Result + MemberAvatar(Item.Get('author', ''), Item.Get('avatar', ''));
    Result := Result + '<strong>' + MemberLink(Item.Get('author', '')) + '</strong>';
    BadgeCaption := '';
    case Item.Get('badge', '') of
      'admin': BadgeCaption := Say('Administrator');
      'moderator': BadgeCaption := Say('Moderator');
      'bot': BadgeCaption := Say('Bot');
    end;
    if BadgeCaption <> '' then Result := Result + '<span class="forum-mark">' + E(BadgeCaption) + '</span>';
    Result := Result + '<span>' + E(SayCount(Item.Get('post_count', 0), '%d post', '%d posts')) + '</span><span>' + W('Joined') + ' ' +
      DateTag(Item.Get('joined', ''), False) + '</span></aside><div class="forum-post-content"><header><h3>' + E(Subject) + '</h3>' +
      DateTag(Item.Get('created', ''), True) + ' · ' + Link(ForumPostUrl(Topic.Get('id', 0), Item.Get('id', 0)), '#' + IntToStr(Item.Get('number', I + 1))) + '</header>';
    if Item.Get('hidden', False) then
      Result := Result + '<p class="forum-hidden">' + W('This post is hidden.') + '</p>';
    // Only the shared renderer supplies post HTML; all metadata is escaped.
    if Item.Find('html') <> nil then
      Result := Result + '<div class="forum-body body">' + Item.Get('html', '') + '</div>';
    if Item.Get('edited', '') <> '' then
      Result := Result + '<p class="forum-edited">' + W('Edited by') + ' ' + E(Item.Get('editor', '')) + ' · ' + DateTag(Item.Get('edited', ''), True) + '</p>';
    if Moderate(Me) then
      Result := Result + HideDetails(Item);
    Actions := '';
    Panels := '';
    if Writable(Me) and not Topic.Get('hidden', False) and (not Topic.Get('locked', False) or Moderate(Me)) and (Item.Find('body') <> nil) then
      Actions := Actions + '<button type="button" class="forum-quote" data-author="' + E(Item.Get('author', '')) + '" data-topic="' +
        IntToStr(Topic.Get('id', 0)) + '" data-post="' + IntToStr(Item.Get('id', 0)) + '" data-body="' + E(Item.Get('body', '')) + '">' + W('Quote') + '</button>';
    MayChange := ForumMayChange(Me.Id, Item.Get('author_id', 0), Writable(Me), Moderate(Me), Topic.Get('locked', False), Item.Get('hidden', False) or
      Topic.Get('hidden', False));
    if MayChange then
    begin
      Fields := HiddenField('id', IntToStr(Item.Get('id', 0))) + HiddenField('topic_id', IntToStr(Topic.Get('id', 0)));
      PanelId := 'edit-post-' + IntToStr(Item.Get('id', 0));
      Actions := Actions + PostAction(PanelId, Say('Modify'));
      if Item.Get('id', 0) = Topic.Get('first_post_id', 0) then
        Panels := Panels + ActionPanel(PanelId, Form('post/edit', Fields + Input('title', Say('Title'), Topic.Get('title', ''), 200) +
          Editor(Item.Get('body', ''), ForumUploadAttributes(Me)), Say('Save')))
      else
        Panels := Panels + ActionPanel(PanelId, Form('post/edit', Fields + Editor(Item.Get('body', ''), ForumUploadAttributes(Me)), Say('Save')));
      PanelId := 'remove-post-' + IntToStr(Item.Get('id', 0));
      Actions := Actions + PostAction(PanelId, Say('Remove'));
      Panels := Panels + ActionPanel(PanelId, '<p>' + W('Delete this post?') + '</p>' + Form('post/delete', Fields, Say('Remove')));
    end;
    if Moderate(Me) then
    begin
      PanelId := 'moderate-post-' + IntToStr(Item.Get('id', 0));
      Caption := Say('Hide');
      if Item.Get('hidden', False) then Caption := Say('Restore');
      Actions := Actions + PostAction(PanelId, Caption);
      Panels := Panels + ActionPanel(PanelId, HideForm('post', 'id', Item.Get('id', 0), Item.Get('hidden', False)));
    end;
    if Actions <> '' then Result := Result + '<div class="forum-actions" data-forum-tools hidden>' + Actions + '</div>';
    Result := Result + Panels + '</div></article>';
  end;
end;

function Breadcrumb(Board: TJSONObject; List: TJSONArray): string;
var
  I: integer;
  Parent: TJSONObject;
  CategoryName: string;
begin
  CategoryName := Board.Get('category', '');
  if CategoryName = '' then CategoryName := Say('General');
  Result := '<nav class="forum-crumbs" aria-label="' + W('Breadcrumb') + '">' + Link('/', Say('Home')) + ' › ' + Link('/forum', Say('Forum'));
  Parent := nil;
  for I := 0 to List.Count - 1 do
    if TJSONObject(List[I]).Get('id', 0) = Board.Get('parent_id', -1) then Parent := TJSONObject(List[I]);
  if Parent <> nil then
  begin
    CategoryName := Parent.Get('category', Say('General'));
    if CategoryName = '' then CategoryName := Say('General');
    Result := Result + ' › ' + Link('/forum#category-' + IntToStr(Parent.Get('category_id', 0)), CategoryName) + ' › ' +
      Link(ForumBoardUrl(Parent.Get('slug', '')), Parent.Get('name', ''));
  end
  else
    Result := Result + ' › ' + Link('/forum#category-' + IntToStr(Board.Get('category_id', 0)), CategoryName);
  Result := Result + ' › ' + Link(ForumBoardUrl(Board.Get('slug', '')), Board.Get('name', '')) + '</nav>';
end;

function InfoHtml(Data: TJSONObject; Boards: TJSONArray): string;
var
  I: integer;
  Posts, Topics: int64;
  Item: TJSONObject;
begin
  Posts := 0;
  Topics := 0;
  for I := 0 to Boards.Count - 1 do
  begin
    Item := TJSONObject(Boards[I]);
    Inc(Posts, Item.Get('post_count', int64(0)));
    Inc(Topics, Item.Get('topic_count', int64(0)));
  end;
  Result := '<section class="forum-info"><h2>' + W('Forum information') + '</h2><p>' + E(SayCount(Posts, '%d post', '%d posts')) + ' · ' +
    E(SayCount(Topics, '%d topic', '%d topics')) + ' · ' + E(SayCount(Data.Get('members', 0), '%d member', '%d members')) + '</p><p>' +
    W('Newest member') + ': ' + MemberLink(Data.Get('newest', '')) + '</p><h3>' + W('Latest posts') + '</h3><ul>';
  for I := 0 to Data.Arrays['posts'].Count - 1 do
  begin
    Item := TJSONObject(Data.Arrays['posts'][I]);
    Result := Result + '<li>' + Link(ForumPostUrl(Item.Get('topic_id', 0), Item.Get('id', 0)), Item.Get('title', '')) + ' · ' +
      MemberLink(Item.Get('author', '')) + ' · ' + DateTag(Item.Get('created', ''), True) + '</li>';
  end;
  Result := Result + '</ul></section>';
end;

procedure ShowForum(R: TRequest; S: TResponse);
var
  Me: TMember;
  Data, Topic, Board: TJSONObject;
  List: TJSONArray;
  Path, Slug, Title, Heading, Content, Address, SearchText, Who: string;
  Id, Page, PageCount: integer;
begin
  Data := nil;
  List := nil;
  try
    try
      CheckConnection;
      if not ForumOn then
        Refuse(404, 'Nothing here.');
      Path := ExcludeTrailingPathDelimiter(HTTPDecode(R.PathInfo));
      // This file announces the lazy admin script only while the forum is on.
      if Path = '/forum/admin.js' then
      begin
        S.ContentType := 'application/javascript; charset=utf-8';
        S.SetCustomHeader('Cache-Control', 'private, no-store');
        S.Content := 'window.Chat.extras.adminScripts.push({src:"/static/forum-admin.js",permissions:["forum-boards"]});';
        S.SendContent;
        Exit;
      end;
      Me := CurrentMember(R);
      if not Can(Me, 'forum-read') then
        Refuse(404, 'Nothing here.');
      Page := ForumPage(R.QueryFields.Values['page']);
      Title := Say('Forum');
      Heading := '';
      Address := '/forum';
      SearchText := '';
      Content := '';
      if Path = '/forum' then
      begin
        Page := 1;
        List := Boards(Me, False);
        Content := ForumBoardTree(List, 0);
        Data := ForumInfo(Me);
        Content := Content + InfoHtml(Data, List);
        if Me.Id > 0 then Content := Content + Form('read', '', Say('Mark all read'));
        if Content = '' then
          Content := '<p>' + W('No boards found.') + '</p>';
      end
      else if (Path = '/forum/recent') or (Path = '/forum/unread') then
      begin
        Title := Say('Recent posts');
        if Path = '/forum/unread' then Title := Say('Unread posts');
        Address := Path;
        Data := Recent(Page, Me, Path = '/forum/unread');
        if Path = '/forum/recent' then Content := ForumRecentHtml(Data.Arrays['topics'])
        else
          Content := ForumTopicsHtml(Data.Arrays['topics']);
        Content := ForumPager(Address, Page, Data.Get('has_more', False)) + Content + ForumPager(Address, Page, Data.Get('has_more', False));
        if Path = '/forum/unread' then Content := Content + Form('read', '', Say('Mark all read'));
      end
      else if Path = '/forum/search' then
      begin
        Title := Say('Search the forum');
        Address := Path;
        SearchText := Trim(R.QueryFields.Values['q']);
        if SearchText = '' then
          Page := 1;
        if SearchText <> '' then
        begin
          Data := Search(SearchText, Page, Me);
          Content := '<p>' + E(Format(Say('Results for %s'), [SearchText])) + '</p>' + ForumTopicsHtml(Data.Arrays['topics']) +
            ForumPager(Address, Page, Data.Get('has_more', False), SearchText);
        end;
      end
      else if Path.StartsWith('/forum/t/') then
      begin
        if not TryStrToInt(Copy(Path, 10, MaxInt), Id) or (Id <= 0) then
          Refuse(404, 'Nothing here.');
        if R.QueryFields.Values['post'] <> '' then
        begin
          Page := PostPage(Id, StrToIntDef(R.QueryFields.Values['post'], 0), Me);
          S.Code := 303;
          S.Location := ForumPageUrl(ForumTopicUrl(Id), Page) + '#post-' + IntToStr(StrToIntDef(R.QueryFields.Values['post'], 0));
          S.SendContent;
          Exit;
        end;
        Data := TopicPage(Id, Page, Me);
        Topic := Data.Objects['topic'];
        PageCount := ForumPageForPosition(Topic.Get('display_count', 0));
        if Moderate(Me) then PageCount := ForumPageForPosition(Topic.Get('post_count', 0));
        Title := Topic.Get('title', '');
        Address := ForumTopicUrl(Id);
        List := Boards(Me, False);
        Board := nil;
        for Id := 0 to List.Count - 1 do
          if TJSONObject(List[Id]).Get('id', 0) = Topic.Get('board_id', 0) then
            Board := TJSONObject(List[Id]);
        if Board = nil then
          Refuse(404, 'Nothing here.');
        Content := Breadcrumb(Board, List) + '<div class="forum-titlebar"><h1>' + E(Title) + '</h1>' + Marks(Topic) + '</div>';
        if Writable(Me) and not Topic.Get('hidden', False) and (not Topic.Get('locked', False) or Moderate(Me)) then
          Content := Content + '<a class="primary" href="#quick-reply">' + W('Reply') + '</a>';
        if Moderate(Me) then
          Content := Content + HideDetails(Topic) + TopicTools(Topic, List);
        Content := Content + '<div class="forum-pagebar">' + ForumPager(Address, Page, Data.Get('has_more', False), '', PageCount) +
          PageJump(True) + '</div>' + ForumPostsHtml(Data, Me) + '<div class="forum-pagebar">' + ForumPager(Address, Page, Data.Get('has_more', False), '', PageCount) +
          PageJump(False) + '</div>';
        if Writable(Me) and not Topic.Get('hidden', False) and (not Topic.Get('locked', False) or Moderate(Me)) then
          Content := Content + '<section id="quick-reply" data-forum-tools hidden><h2>' + W('Quick reply') + '</h2>' +
            Form('reply', HiddenField('topic_id', IntToStr(Topic.Get('id', 0))) + Editor('', ForumUploadAttributes(Me)), Say('Post reply')) + '</section>';
      end
      else if Path.StartsWith('/forum/') then
      begin
        Slug := Copy(Path, 8, MaxInt);
        if (Slug = '') or (ForumSlug(Slug) <> Slug) then
          Refuse(404, 'Nothing here.');
        Id := IntValue('SELECT id FROM forum_boards WHERE slug = :s', [Slug]);
        if Id = 0 then
          Refuse(404, 'Nothing here.');
        Data := BoardPage(Id, Page, Me);
        Board := Data.Objects['board'];
        PageCount := ForumPageForPosition(Board.Get('topic_count', 0));
        if Moderate(Me) then PageCount := ForumPageForPosition(Board.Get('total_topic_count', 0));
        Title := Board.Get('name', '');
        Address := ForumBoardUrl(Board.Get('slug', ''));
        List := Boards(Me, False);
        Content := Breadcrumb(Board, List) + '<div class="forum-titlebar"><div><h1>' + E(Title) + '</h1><p class="forum-description">' +
          E(Board.Get('description', '')) + '</p></div></div>';
        if Writable(Me) then Content := Content + '<a class="primary" href="#new-topic" data-forum-new>' + W('New topic') + '</a>';
        Content := Content + ForumBoardTree(List, Id) + '<div class="forum-pagebar">' + ForumPager(Address, Page, Data.Get('has_more', False), '', PageCount) +
          PageJump(True) + '</div>' + ForumTopicsHtml(Data.Arrays['topics']) + '<div class="forum-pagebar">' + ForumPager(Address,
          Page, Data.Get('has_more', False), '', PageCount) + PageJump(False) + '</div>';
        if Writable(Me) then
        begin
          Content := Content + '<details id="new-topic" data-forum-tools hidden><summary>' + W('New topic') + '</summary>' +
            Form('topic/new', HiddenField('board_id', IntToStr(Id)) + Input('title', Say('Title'), '', 200) + Editor('', ForumUploadAttributes(Me)), Say('Create topic')) +
            '</details>';
        end;
      end
      else
        Refuse(404, 'Nothing here.');
      if (Path = '/forum') or (Path = '/forum/search') or (Path = '/forum/recent') or (Path = '/forum/unread') then
        Heading := '<h1>' + E(Title) + '</h1>';
      Who := 'guest';
      if Me.Id > 0 then
        Who := 'member';
      // CanonicalUrl supplies the site's origin; normalized paths retain paging and search.
      Slug := CanonicalUrl(R);
      Id := Pos('/', Slug, Pos('://', Slug) + 3);
      if Id > 0 then
        Slug := Copy(Slug, 1, Id - 1);
      SendPage(S, FillTemplate('forum', ['title', E(Title), 'account', AccountBox(Me), 'who', Who, 'canonical', E(Slug + ForumPageUrl(Address, Page, SearchText)),
        'heading', Heading, 'content', Content, 'query', E(SearchText)]));
    except
      on Ex: EForumRequest do
        SendText(S, Ex.Code, Say(Ex.Message));
    end;
  finally
    List.Free;
    Data.Free;
  end;
end;

procedure RegisterForumPages;
begin
  HTTPRouter.RegisterRoute('/forum', rmGet, @ShowForum);
  HTTPRouter.RegisterRoute('/forum/*path', rmGet, @ShowForum);
  RegisterVisitorPart('forum', '/forum');
  RegisterSearchPlace('/forum/search', 'forum');
  RegisterSearchPlace('/api/forum/search', 'forum');
  RegisterSearchRoute('/forum/search');
end;

end.
