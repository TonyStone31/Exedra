unit SiteParts;

{ The parts of the suite a site owner turns on or off: the chat, the wiki,
  the forum.  A part registers itself, the addresses that are its own and
  the scripts the site's page loads for it.  While a part is off its
  addresses answer 404 and its scripts stay out of the page; its tables
  are left alone.

  The switch is a setting by the part's name (chat, wiki, forum), so it
  can be set in the admin's Settings or in the ini ([site] chat=0). }

{$mode objfpc}{$H+}

interface

procedure RegisterPart(const Name, Caption: string; DefaultOn: boolean);
function PartOn(const Name: string): boolean;
{ Addresses that belong to a part: each one itself and everything under it. }
procedure RegisterPartPaths(const Part: string; const Paths: array of string);
{ The part an address belongs to, or ''. }
function PartOfPath(const Path: string): string;
{ A script the site's page loads while the part is on. }
procedure RegisterPartScript(const Part, Src: string);
{ The script tags of the parts that are on; Version goes on each address. }
function PartScriptTags(const Version: string): string;
{ The names of the parts that are on, separated by spaces. }
function PartsOn: string;

type
  TPartProc = procedure;
  TPartLink = function: string;

{ Work a part does when the program starts, after the site is open; it
  runs only while the part is on. }
procedure RegisterPartStart(const Part: string; Start: TPartProc);
procedure StartParts;
{ A part's link in the bar at the top of the site's pages: Make gives the
  whole <a>, or '' for none right now. }
procedure RegisterPartLink(const Part: string; Make: TPartLink);
{ The links of the parts that are on. }
function PartLinks: string;
{ Where a part's own front page is.  A site with one part on opens there. }
procedure RegisterPartHome(const Part, Address: string);
{ The front page of the only part that is on; '' with none, several, or
  when that part named no front page. }
function OnlyPartHome: string;

implementation

uses
  SysUtils, httpdefs, httproute, ChatDb, SiteWords;

type
  TPart = record
    Name: string;
    DefaultOn: boolean;
  end;

  TPartPath = record
    Part, Path: string;
  end;

  TPartSwitch = class
    procedure Check(R: TRequest; S: TResponse; var ContinueRequest: boolean);
  end;

var
  Parts: array of TPart;
  Paths: array of TPartPath;
  Scripts: array of TPartPath;
  Starts: array of record
    Part: string;
    Start: TPartProc;
    end;
  Homes: array of TPartPath;
  Links: array of record
    Part: string;
    Make: TPartLink;
    end;
  Switch: TPartSwitch;

procedure RegisterPart(const Name, Caption: string; DefaultOn: boolean);
var
  I: integer;
begin
  for I := 0 to High(Parts) do
    if Parts[I].Name = Name then
      raise Exception.Create('Duplicate part: ' + Name);
  SetLength(Parts, Length(Parts) + 1);
  Parts[High(Parts)].Name := Name;
  Parts[High(Parts)].DefaultOn := DefaultOn;
  RegisterSetting(Name, Caption, IntToStr(Ord(DefaultOn)), 'yesno', 'Parts');
end;

function PartOn(const Name: string): boolean;
var
  I: integer;
begin
  for I := 0 to High(Parts) do
    if Parts[I].Name = Name then
      Exit(Setting(Name, IntToStr(Ord(Parts[I].DefaultOn))) = '1');
  Result := False;
end;

procedure RegisterPartPaths(const Part: string; const Paths: array of string);
var
  P: string;
begin
  for P in Paths do
  begin
    SetLength(SiteParts.Paths, Length(SiteParts.Paths) + 1);
    SiteParts.Paths[High(SiteParts.Paths)].Part := Part;
    SiteParts.Paths[High(SiteParts.Paths)].Path := LowerCase(P);
  end;
end;

function PartOfPath(const Path: string): string;
var
  I, Best: integer;
  Lower: string;
begin
  Result := '';
  Best := 0;
  Lower := LowerCase(Path);
  // the longest registered address wins, so a part can own one under another's
  for I := 0 to High(Paths) do
    if (Length(Paths[I].Path) > Best) and ((Lower = Paths[I].Path) or Lower.StartsWith(Paths[I].Path + '/')) then
    begin
      Best := Length(Paths[I].Path);
      Result := Paths[I].Part;
    end;
end;

procedure RegisterPartScript(const Part, Src: string);
begin
  SetLength(Scripts, Length(Scripts) + 1);
  Scripts[High(Scripts)].Part := Part;
  Scripts[High(Scripts)].Path := Src;
end;

function PartScriptTags(const Version: string): string;
var
  I: integer;
begin
  Result := '';
  for I := 0 to High(Scripts) do
    if PartOn(Scripts[I].Part) then
      Result := Result + '<script src="' + Scripts[I].Path + '?v=' + Version + '"></script>'#10;
  Result := TrimRight(Result);
end;

function PartsOn: string;
var
  I: integer;
begin
  Result := '';
  for I := 0 to High(Parts) do
    if PartOn(Parts[I].Name) then
      Result := Result + Parts[I].Name + ' ';
  Result := TrimRight(Result);
end;

procedure RegisterPartStart(const Part: string; Start: TPartProc);
begin
  SetLength(Starts, Length(Starts) + 1);
  Starts[High(Starts)].Part := Part;
  Starts[High(Starts)].Start := Start;
end;

procedure StartParts;
var
  I: integer;
begin
  for I := 0 to High(Starts) do
    if PartOn(Starts[I].Part) then
      Starts[I].Start();
end;

procedure RegisterPartLink(const Part: string; Make: TPartLink);
begin
  SetLength(Links, Length(Links) + 1);
  Links[High(Links)].Part := Part;
  Links[High(Links)].Make := Make;
end;

function PartLinks: string;
var
  I: integer;
begin
  Result := '';
  for I := 0 to High(Links) do
    if PartOn(Links[I].Part) then
      Result := Result + Links[I].Make();
end;

procedure RegisterPartHome(const Part, Address: string);
begin
  SetLength(Homes, Length(Homes) + 1);
  Homes[High(Homes)].Part := Part;
  Homes[High(Homes)].Path := Address;
end;

function OnlyPartHome: string;
var
  I: integer;
  Only: string;
begin
  Result := '';
  Only := PartsOn;
  if (Only = '') or (Pos(' ', Only) > 0) then
    Exit;
  for I := 0 to High(Homes) do
    if Homes[I].Part = Only then
      Exit(Homes[I].Path);
end;

procedure TPartSwitch.Check(R: TRequest; S: TResponse; var ContinueRequest: boolean);
var
  Part: string;
begin
  ContinueRequest := True;
  Part := PartOfPath(HTTPDecode(R.PathInfo));
  if (Part = '') or PartOn(Part) then
    Exit;
  ContinueRequest := False;
  SetRequestLanguage(CookieLanguage(R));
  S.Code := 404;
  S.ContentType := 'text/plain; charset=utf-8';
  S.SetCustomHeader('Cache-Control', 'private, no-store');
  S.Content := Say('Nothing here.');
  S.SendContent;
end;

initialization
  Switch := TPartSwitch.Create;
  HTTPRouter.RegisterInterceptor('parts', @Switch.Check);

finalization
  HTTPRouter.UnRegisterInterceptor('parts');
  Switch.Free;
end.
