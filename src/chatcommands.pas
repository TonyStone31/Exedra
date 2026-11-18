unit ChatCommands;

{ The commands IRC people reach for, typed in any message box:

  /join #room    /part           /away [why]    /back
  /whois name    /names          /invite name   /kick name
  /op name       /deop name      /mute name [minutes]   /unmute name
  /ban name      /unban name     /ignore name   /unignore name

  /msg and /list are done by the page itself, since a private message is
  encrypted before it leaves the browser.  Each command checks the same
  permissions the buttons do. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Classes, SysUtils, Variants, ChatDb, SiteSql, ChatUsers, ChatRooms, ChatMessages, ChatRoles, ChatBell;

{ The member a command names: its first word, @ or not. }
function Target(const Args: string; out Id: integer; out Name: string): boolean;
begin
  Name := Trim(Copy(Args + ' ', 1, Pos(' ', Args + ' ') - 1));
  if Name.StartsWith('@') then
    Delete(Name, 1, 1);
  Id := MemberId(Name);
  if Id > 0 then
    Name := VarToStr(Value('SELECT name FROM users WHERE id = :u', [Id]));
  Result := Id > 0;
end;

function Info(const Text: string): TCommandResult;
begin
  Result := CommandResult('', Text);
end;

{ Site moderators, admins and the room's owner cannot be pushed around in
  it by others. }
function Untouchable(UserId: integer; const Room: TRoom): boolean;
var
  Roles: string;
begin
  Roles := VarToStr(Value('SELECT roles FROM users WHERE id = :u', [UserId]));
  Result := (UserId = Room.OwnerId) or HasRole(Roles, 'admin') or HasRole(Roles, 'moderator');
end;

function JoinCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Other: TRoom;
begin
  Other := FindRoom(LowerCase(Trim(StringReplace(Args, '#', '', []))));
  if not CanRead(Me, Other) then
    Exit(Info('No channel by that name.'));
  Follow(Me.Id, Other.Id);
  Result := CommandResult('', '', '/p/' + Other.Slug);
end;

function PartCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Other: TRoom;
begin
  Other := Room;
  if Trim(Args) <> '' then
    Other := FindRoom(LowerCase(Trim(StringReplace(Args, '#', '', []))));
  if not IsFollower(Me.Id, Other.Id) then
    Exit(Info('You are not in that channel.'));
  Exec('DELETE FROM follows WHERE user_id = :u AND room_id = :r', [Me.Id, Other.Id]);
  if Other.Private then
    Result := CommandResult('', 'You left. Someone in it has to invite you back.', '/')
  else
    Result := CommandResult('', 'It is out of your sidebar. /join #' + Other.Slug + ' brings it back.', '/');
end;

function AwayCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Why: string;
begin
  Why := Copy(Trim(Args), 1, 200);
  if Why = '' then
    Why := 'away';
  Exec('UPDATE users SET away = :a WHERE id = :u', [Why, Me.Id]);
  Result := Info('You are away: ' + Why + '. People who mention you are told. /back when you return.');
end;

function BackCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
begin
  Exec('UPDATE users SET away = '''' WHERE id = :u', [Me.Id]);
  Result := Info('Welcome back.');
end;

function WhoisCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Who, Lines: string;
begin
  if not Target(Args, Id, Who) then
    Exit(Info('No member by that name.'));
  with Query('SELECT roles, ' + IsoTime('created') + ', ' + IsoTime('last_seen') + ', away, posts, banned FROM users WHERE id = :u', [Id]) do
  try
    Lines := Who;
    if Fields[0].AsString <> '' then
      Lines := Lines + ' (' + Fields[0].AsString + ')';
    Lines := Lines + #10 + 'joined ' + Copy(Fields[1].AsString, 1, 10) + ', last here ' + StringReplace(Copy(Fields[2].AsString, 1, 16), 'T', ' ', []) +
      ' UTC' + #10 + IntToStr(Fields[4].AsInteger) + ' messages';
    if Fields[3].AsString <> '' then
      Lines := Lines + #10 + 'away: ' + Fields[3].AsString;
    if Fields[5].AsInteger = 1 then
      Lines := Lines + #10 + 'banned';
  finally
    Free;
  end;
  if IntValue('SELECT COUNT(*) FROM presence WHERE user_id = :u AND seen > ' + SqlAgo('2', suMinute), [Id]) > 0 then
    Lines := Lines + #10 + 'online now';
  Result := Info(Lines);
end;

function NamesCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Here: string;
  I: integer;
begin
  Here := '';
  with HereNow(Room.Id) do
  try
    for I := 0 to Count - 1 do
      Here := Here + ' ' + Objects[I].Strings['name'];
  finally
    Free;
  end;
  if Here = '' then
    Result := Info('Nobody else is looking at this channel right now.')
  else
    Result := Info('Here now:' + Here);
end;

function InviteCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not Room.Private then
    Exit(Info('Anyone can /join a public channel. Mention them with @name instead.'));
  if not RoomCan(Me, 'invite', Room) then
    Exit(Info('Inviting is not open to you in this channel.'));
  if not Target(Args, Id, Name) then
    Exit(Info('No member by that name.'));
  if IsFollower(Id, Room.Id) then
    Exit(Info(Name + ' is in here already.'));
  Follow(Id, Room.Id);
  RingUser(Id, BellNote(['t', 'me']));
  Result := CommandResult('invited @' + Name, '');
end;

function KickCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not Room.Private then
    Exit(Info('A public channel cannot be closed to anyone. /mute them instead.'));
  if not RoomCan(Me, 'kick', Room) then
    Exit(Info('Taking people out is not open to you in this channel.'));
  if not Target(Args, Id, Name) or not IsFollower(Id, Room.Id) then
    Exit(Info('Nobody by that name is in here.'));
  if Untouchable(Id, Room) then
    Exit(Info(Name + ' cannot be taken out of this channel.'));
  Exec('DELETE FROM follows WHERE user_id = :u AND room_id = :r', [Id, Room.Id]);
  Exec('DELETE FROM room_roles WHERE user_id = :u AND room_id = :r', [Id, Room.Id]);
  DropUser(Id);
  Result := CommandResult('took ' + Name + ' out of the channel', '');
end;

function OpCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not RoomCan(Me, 'set-room-roles', Room) then
    Exit(Info('Naming channel moderators is not open to you here.'));
  if not Target(Args, Id, Name) then
    Exit(Info('No member by that name.'));
  Exec(SqlInsertIgnore('room_roles', 'room_id, user_id, role', ':r, :u, ''room-moderator'''),
    [Room.Id, Id]);
  Result := CommandResult('made @' + Name + ' a moderator of this channel', '');
end;

function DeopCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not RoomCan(Me, 'set-room-roles', Room) then
    Exit(Info('Naming channel moderators is not open to you here.'));
  if not Target(Args, Id, Name) then
    Exit(Info('No member by that name.'));
  Exec('DELETE FROM room_roles WHERE room_id = :r AND user_id = :u AND role = ''room-moderator''',
    [Room.Id, Id]);
  Result := Info(Name + ' is no longer a moderator of this channel.');
end;

function MuteCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id, Minutes: integer;
  Name: string;
begin
  if not RoomCan(Me, 'mute', Room) then
    Exit(Info('Muting is not open to you here.'));
  if not Target(Args, Id, Name) then
    Exit(Info('No member by that name.'));
  if Untouchable(Id, Room) then
    Exit(Info(Name + ' cannot be muted here.'));
  Minutes := StrToIntDef(Trim(Copy(Args, Pos(' ', Args + ' '), MaxInt)), 0);
  // The database's clock decides, as everywhere else.
  Exec(SqlReplace('mutes', 'room_id, user_id, until', ':r, :u, ' + SqlIf(':m > 0', SqlAhead(':m2', suMinute), 'NULL')), [Room.Id, Id, Minutes, Minutes]);
  if Minutes > 0 then
    Result := CommandResult(Format('muted %s here for %d minutes', [Name, Minutes]), '')
  else
    Result := CommandResult('muted ' + Name + ' here', '');
end;

function UnmuteCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not RoomCan(Me, 'mute', Room) then
    Exit(Info('Muting is not open to you here.'));
  if not Target(Args, Id, Name) then
    Exit(Info('No member by that name.'));
  Exec('DELETE FROM mutes WHERE room_id = :r AND user_id = :u', [Room.Id, Id]);
  Result := Info(Name + ' can talk here again.');
end;

function BanCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name, Roles: string;
begin
  if not Can(Me, 'ban') then
    Exit(Info('Banning is for moderators.'));
  if not Target(Args, Id, Name) or (Id = Me.Id) then
    Exit(Info('No member by that name.'));
  Roles := VarToStr(Value('SELECT roles FROM users WHERE id = :u', [Id]));
  if (HasRole(Roles, 'admin') or HasRole(Roles, 'moderator')) and not HasRole(Me.Roles, 'admin') then
    Exit(Info('Only an admin bans a moderator.'));
  Exec('UPDATE users SET banned = 1 WHERE id = :u', [Id]);
  Exec('DELETE FROM sessions WHERE user_id = :u', [Id]);
  DropUser(Id);
  Log(Me.Name + ' banned ' + Name);
  Result := Info(Name + ' is banned: signed out everywhere, and can only read now.');
end;

function UnbanCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not Can(Me, 'ban') then
    Exit(Info('Banning is for moderators.'));
  if not Target(Args, Id, Name) then
    Exit(Info('No member by that name.'));
  Exec('UPDATE users SET banned = 0 WHERE id = :u', [Id]);
  Log(Me.Name + ' lifted the ban on ' + Name);
  Result := Info(Name + ' can talk again.');
end;

function IgnoreCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not Target(Args, Id, Name) or (Id = Me.Id) then
    Exit(Info('No member by that name.'));
  Exec(SqlInsertIgnore('ignores', 'user_id, ignored_id', ':u, :o'), [Me.Id, Id]);
  Result := Info('Ignoring ' + Name + ': their messages fold away, their mentions and private' + ' messages do not reach you. /unignore ' + Name + ' undoes it.');
end;

function UnignoreCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Id: integer;
  Name: string;
begin
  if not Target(Args, Id, Name) then
    Exit(Info('No member by that name.'));
  Exec('DELETE FROM ignores WHERE user_id = :u AND ignored_id = :o', [Me.Id, Id]);
  Result := Info('No longer ignoring ' + Name + '.');
end;

initialization
  RegisterCommand('join', '/join #channel - go to a channel and follow it', @JoinCommand);
  RegisterCommand('part', '/part [#channel] - leave a channel (this one if none is named)', @PartCommand);
  RegisterCommand('away', '/away [why] - mark yourself away', @AwayCommand);
  RegisterCommand('back', '/back - you are here again', @BackCommand);
  RegisterCommand('whois', '/whois name - who someone is and when they were here', @WhoisCommand);
  RegisterCommand('names', '/names - who is looking at this channel', @NamesCommand);
  RegisterCommand('invite', '/invite name - into this private channel', @InviteCommand);
  RegisterCommand('kick', '/kick name - out of this private channel', @KickCommand);
  RegisterCommand('op', '/op name - make someone a moderator of this channel', @OpCommand);
  RegisterCommand('deop', '/deop name - take that back', @DeopCommand);
  RegisterCommand('mute', '/mute name [minutes] - stop someone talking in this channel', @MuteCommand);
  RegisterCommand('unmute', '/unmute name', @UnmuteCommand);
  RegisterCommand('ban', '/ban name - stop someone talking anywhere (moderators)', @BanCommand);
  RegisterCommand('unban', '/unban name', @UnbanCommand);
  RegisterCommand('ignore', '/ignore name - fold away what someone says', @IgnoreCommand);
  RegisterCommand('unignore', '/unignore name', @UnignoreCommand);
  RegisterPermission('ban', 'Ban members from the whole site', 'moderator,admin');
end.
