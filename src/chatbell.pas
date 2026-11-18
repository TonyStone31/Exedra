unit ChatBell;

{ Telling open pages that something changed, so they ask at once instead of
  on their next timer.

  The server keeps a live connection (a WebSocket, unit ChatLive) to each
  open page and rings it with a short note: this room changed, someone is
  typing there, you have something new.  A page that hears a ring asks for
  the change the usual way (/api/sync), so a ring never carries anything a
  member may not read.  A CGI program keeps no connections; there the
  rings go nowhere and pages ask every few seconds. }

{$mode objfpc}{$H+}

interface

type
  TRingProc = procedure(const Data: string);
  TRingTargetProc = procedure(Target: integer; const Data: string);
  TWatchProc = procedure(const LiveId: string; UserId, RoomId, ThreadId: integer);
  TLiveFunc = function(UserId: integer): boolean;
  TUserProc = procedure(UserId: integer);

var
  { Set by ChatLive when the server runs; nil in a CGI program. }
  OnRingAll: TRingProc;
  OnRingUser: TRingTargetProc;
  OnRingWatchers: TRingTargetProc;
  OnWatch: TWatchProc;
  OnIsLive: TLiveFunc;
  OnDropUser: TUserProc;

{ Every open page: a public room changed. }
procedure RingAll(const Data: string);
{ The pages of one member. }
procedure RingUser(UserId: integer; const Data: string);
{ The pages showing one room. }
procedure RingWatchers(RoomId: integer; const Data: string);
{ Notes which room (and thread) the page on that live connection shows. }
procedure Watch(const LiveId: string; UserId, RoomId, ThreadId: integer);
{ The member has a page open now (False in a CGI program). }
function UserIsLive(UserId: integer): boolean;
{ Closes the member's live pages after a kick, a ban or a new password; they
  come back with only what the member may see now. }
procedure DropUser(UserId: integer);
{ A ring's text: name, value pairs as JSON. }
function BellNote(const Pairs: array of const): string;

implementation

uses
  fpjson;

function BellNote(const Pairs: array of const): string;
begin
  with TJSONObject.Create(Pairs) do
  try
    Result := AsJSON;
  finally
    Free;
  end;
end;

procedure RingAll(const Data: string);
begin
  if OnRingAll <> nil then
    OnRingAll(Data);
end;

procedure RingUser(UserId: integer; const Data: string);
begin
  if (OnRingUser <> nil) and (UserId > 0) then
    OnRingUser(UserId, Data);
end;

procedure RingWatchers(RoomId: integer; const Data: string);
begin
  if OnRingWatchers <> nil then
    OnRingWatchers(RoomId, Data);
end;

function UserIsLive(UserId: integer): boolean;
begin
  Result := (OnIsLive <> nil) and OnIsLive(UserId);
end;

procedure DropUser(UserId: integer);
begin
  if OnDropUser <> nil then
    OnDropUser(UserId);
end;

procedure Watch(const LiveId: string; UserId, RoomId, ThreadId: integer);
begin
  if (OnWatch <> nil) and (LiveId <> '') then
    OnWatch(LiveId, UserId, RoomId, ThreadId);
end;

end.
