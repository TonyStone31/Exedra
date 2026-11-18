unit ChatRoles;

{ Roles and permissions, the way Rocket.Chat has them.

  A permission is something a member may do (post, pin, ban...); each unit
  registers its own with the roles that have it at first.  A role is a
  name that holds permissions.  Site roles are given to members by an
  admin: admin, moderator, bot and any role an admin makes.  Two site roles
  come by themselves: member (anyone signed in) and guest (anyone else,
  and banned members).  Room roles hold only in one room: owner (whoever
  opened it) and room-moderator (whom the owner names with /op).  An admin
  can change which roles have which permission, and make new roles, from
  the admin page; to give one member one extra right, make a role with
  that right and give it to them.

  Admins may do everything, whatever the table says, so a site cannot lock
  its admins out.  A member muted in a room cannot post or react there. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, ChatUsers;

procedure RegisterPermission(const Name, Caption, DefaultRoles: string);
{ Whether Me may do Perm, by site roles. }
{ Reads who may do what from the table again: after a restore. }
procedure LoadGrants;
function Can(const Me: TMember; const Perm: string): boolean;
{ Whether Me may do Perm in a room, by site roles and roles in the room. }
function CanIn(const Me: TMember; const Perm: string; RoomId, OwnerId: integer): boolean;
function IsMuted(UserId, RoomId: integer): boolean;
{ The site permissions Me has, for the page to know what to show. }
function SitePermissions(const Me: TMember): TJSONArray;
{ The role shown beside a name: admin, moderator, bot, or ''. }
function Badge(const Roles: string): string;
function HasRole(const Roles, Role: string): boolean;
{ For the admin page. }
function RolesJSON: TJSONArray;
function PermissionsJSON: TJSONArray;
function IsRole(const Name: string): boolean;
procedure SetPermissionRoles(const Perm, Roles: string);
procedure AddRole(const Name, Caption, Scope: string);
procedure DeleteRole(const Name: string);

implementation

uses
  StrUtils, ChatDb, SiteSql;

type
  TPermission = record
    Name, Caption, Default: string;
  end;

var
  Defs: array of TPermission;
  { name=role,role for every permission, as the database has it. }
  Granted: TStringList;
  GrantLock: TRTLCriticalSection;

const
  BuiltIn: array[0..6, 0..2] of string = (
    ('admin', 'Runs the site; may do everything', 'site'),
    ('moderator', 'Keeps the peace everywhere', 'site'),
    ('bot', 'An account a program runs', 'site'),
    ('member', 'Everyone signed in', 'site'),
    ('guest', 'Anyone not signed in, and banned members', 'site'),
    ('owner', 'Opened the channel', 'room'),
    ('room-moderator', 'Named by the channel''s owner', 'room'));
  { What a muted member cannot do in that room. }
  TalkPermissions: array[0..2] of string = ('post', 'react', 'upload');

procedure RegisterPermission(const Name, Caption, DefaultRoles: string);
begin
  SetLength(Defs, Length(Defs) + 1);
  Defs[High(Defs)].Name := Name;
  Defs[High(Defs)].Caption := Caption;
  Defs[High(Defs)].Default := DefaultRoles;
end;

function HasRole(const Roles, Role: string): boolean;
begin
  Result := AnsiMatchText(Role, Roles.Split([','], TStringSplitOptions.ExcludeEmpty));
end;

procedure LoadGrants;
begin
  EnterCriticalSection(GrantLock);
  try
    Granted.Clear;
    with Query('SELECT name, roles FROM permissions', []) do
    try
      while not EOF do
      begin
        Granted.Add(Fields[0].AsString + '=' + Fields[1].AsString);
        Next;
      end;
    finally
      Free;
    end;
  finally
    LeaveCriticalSection(GrantLock);
  end;
end;

procedure Seed;
var
  I: integer;
  P: TPermission;
begin
  for I := 0 to High(BuiltIn) do
    Exec(SqlInsertIgnore('roles', 'name, caption, scope, builtin', ':n, :c, :s, 1'),
      [BuiltIn[I, 0], BuiltIn[I, 1], BuiltIn[I, 2]]);
  for P in Defs do
    Exec(SqlInsertIgnore('permissions', 'name, roles', ':n, :r'), [P.Name, P.Default]);
  LoadGrants;
end;

function RolesFor(const Perm: string): string;
var
  I: integer;
begin
  EnterCriticalSection(GrantLock);
  try
    I := Granted.IndexOfName(Perm);
    if I >= 0 then
      Result := Granted.ValueFromIndex[I]
    else
      Result := '';
  finally
    LeaveCriticalSection(GrantLock);
  end;
end;

{ The site roles a member has right now, comma separated. }
function SiteRoles(const Me: TMember): string;
begin
  if (Me.Id = 0) or Me.Banned then
    Result := 'guest'
  else
    Result := Me.Roles + ',member';
end;

function AnyRole(const Have, Need: string): boolean;
var
  R: string;
begin
  Result := False;
  for R in Have.Split([','], TStringSplitOptions.ExcludeEmpty) do
    if HasRole(Need, R) then
      Exit(True);
end;

function IsAdminRole(const Me: TMember): boolean;
begin
  Result := (Me.Id > 0) and not Me.Banned and HasRole(Me.Roles, 'admin');
end;

function Can(const Me: TMember; const Perm: string): boolean;
begin
  Result := IsAdminRole(Me) or AnyRole(SiteRoles(Me), RolesFor(Perm));
end;

function IsMuted(UserId, RoomId: integer): boolean;
begin
  Result := IntValue('SELECT COUNT(*) FROM mutes WHERE room_id = :r AND user_id = :u' + ' AND (until IS NULL OR until > NOW())', [RoomId, UserId]) > 0;
end;

function CanIn(const Me: TMember; const Perm: string; RoomId, OwnerId: integer): boolean;
var
  Have: string;
begin
  if IsAdminRole(Me) then
    Exit(True);
  Have := SiteRoles(Me);
  if (Me.Id > 0) and not Me.Banned then
  begin
    if AnsiMatchStr(Perm, TalkPermissions) and IsMuted(Me.Id, RoomId) then
      Exit(False);
    if OwnerId = Me.Id then
      Have := Have + ',owner';
    with Query('SELECT role FROM room_roles WHERE room_id = :r AND user_id = :u', [RoomId, Me.Id]) do
    try
      while not EOF do
      begin
        Have := Have + ',' + Fields[0].AsString;
        Next;
      end;
    finally
      Free;
    end;
  end;
  Result := AnyRole(Have, RolesFor(Perm));
end;

function SitePermissions(const Me: TMember): TJSONArray;
var
  P: TPermission;
begin
  Result := TJSONArray.Create;
  for P in Defs do
    if Can(Me, P.Name) then
      Result.Add(P.Name);
end;

function Badge(const Roles: string): string;
begin
  if HasRole(Roles, 'admin') then
    Result := 'admin'
  else if HasRole(Roles, 'moderator') then
    Result := 'moderator'
  else if HasRole(Roles, 'bot') then
    Result := 'bot'
  else
    Result := '';
end;

function RolesJSON: TJSONArray;
begin
  Result := TJSONArray.Create;
  with Query('SELECT name, caption, scope, builtin FROM roles ORDER BY builtin DESC, scope DESC, name', []) do
  try
    while not EOF do
    begin
      Result.Add(TJSONObject.Create(['name', Fields[0].AsString, 'caption', Fields[1].AsString, 'scope', Fields[2].AsString, 'builtin', Fields[3].AsInteger = 1]));
      Next;
    end;
  finally
    Free;
  end;
end;

function PermissionsJSON: TJSONArray;
var
  P: TPermission;
begin
  Result := TJSONArray.Create;
  for P in Defs do
    Result.Add(TJSONObject.Create(['name', P.Name, 'caption', P.Caption, 'roles', RolesFor(P.Name)]));
end;

function IsRole(const Name: string): boolean;
begin
  Result := IntValue('SELECT COUNT(*) FROM roles WHERE name = :n', [Name]) > 0;
end;

procedure SetPermissionRoles(const Perm, Roles: string);
begin
  Exec(SqlReplace('permissions', 'name, roles', ':n, :r'), [Perm, Copy(Roles, 1, 500)]);
  LoadGrants;
end;

procedure AddRole(const Name, Caption, Scope: string);
begin
  Exec('INSERT INTO roles (name, caption, scope, builtin) VALUES (:n, :c, :s, 0)',
    [Name, Copy(Caption, 1, 100), Scope]);
end;

procedure DeleteRole(const Name: string);
var
  P: TPermission;
  Left: string;
  R: string;
begin
  Exec('DELETE FROM roles WHERE name = :n AND builtin = 0', [Name]);
  Exec('DELETE FROM room_roles WHERE role = :n', [Name]);
  Exec('UPDATE users SET roles = TRIM(BOTH '','' FROM REPLACE(' + SqlConcat([''',''', 'roles', ''',''']) + ', ' + SqlConcat([''',''', ':n', ''',''']) +
    ', '',''))' + ' WHERE FIND_IN_SET(:n2, roles)', [Name, Name]);
  for P in Defs do
    if HasRole(RolesFor(P.Name), Name) then
    begin
      Left := '';
      for R in RolesFor(P.Name).Split([',']) do
        if R <> Name then
          if Left = '' then
            Left := R
          else
            Left := Left + ',' + R;
      SetPermissionRoles(P.Name, Left);
    end;
end;

procedure ForgetOldMutes;
begin
  Exec('DELETE FROM mutes WHERE until < NOW()', []);
end;

initialization
  InitCriticalSection(GrantLock);
  Granted := TStringList.Create;
  RegisterTable('CREATE TABLE IF NOT EXISTS roles (' + ' name VARCHAR(30) PRIMARY KEY, caption VARCHAR(100) NOT NULL DEFAULT '''',' +
    ' scope VARCHAR(4) NOT NULL DEFAULT ''site'', builtin TINYINT NOT NULL DEFAULT 0' + ') CHARACTER SET utf8mb4');
  RegisterTable('CREATE TABLE IF NOT EXISTS permissions (' + ' name VARCHAR(40) PRIMARY KEY, roles VARCHAR(500) NOT NULL DEFAULT ''''' + ') CHARACTER SET utf8mb4');
  RegisterTable('CREATE TABLE IF NOT EXISTS room_roles (' + ' room_id INT NOT NULL, user_id INT NOT NULL, role VARCHAR(30) NOT NULL,' +
    ' PRIMARY KEY (room_id, user_id, role), INDEX (user_id)) CHARACTER SET utf8mb4');
  RegisterTable('CREATE TABLE IF NOT EXISTS mutes (' + ' room_id INT NOT NULL, user_id INT NOT NULL, until DATETIME NULL,' + ' PRIMARY KEY (room_id, user_id))');
  RegisterStartup(@Seed);
  RegisterChore(@ForgetOldMutes, 10);
end.
