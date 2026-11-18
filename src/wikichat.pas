unit WikiChat;

{ Where the wiki and the chat meet, for a site with both: the chat's /wiki
  command, and #channel in a wiki page as a link to the channel. }

{$mode objfpc}{$H+}

interface

implementation

uses
  SysUtils, ChatDb, ChatUsers, ChatRooms, ChatMessages, SiteWords, Wiki;

function WikiCommand(const Me: TMember; const Room: TRoom; Parent: integer; const Args: string): TCommandResult;
var
  Slug, Url: string;
begin
  Slug := SlugOf(Args);
  if Slug = '' then
    Slug := MAIN_PAGE;
  Url := ExcludeTrailingPathDelimiter(Setting('url', '')) + PageUrl(Slug);
  if PageExists(Slug) then
    Result := CommandResult('', Url)
  else
    Result := CommandResult('', Format(SiteWord(RequestLanguage, 'There is no page by this name yet.') + ' ' + SiteWord(RequestLanguage, 'Write it: %s'), [Url + '?edit=1']));
end;

initialization
  WikiRoomThere := @RoomExists;
  RegisterCommand('wiki', '/wiki [Page Name] - find a wiki page, or write it', @WikiCommand);
end.
