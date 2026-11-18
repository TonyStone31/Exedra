unit ChatCgiGuard;

{$mode objfpc}{$H+}

interface

function AcceptCgiRequest: boolean;

implementation

uses SysUtils, StrUtils, custcgi, ChatDb, ChatGuard, ChatGuardRules;

function AcceptCgiRequest: boolean;
var
  Method, Path, Env, Reply: string;
  Size: int64;
  Code, Headers, I: integer;
begin
  Method := GetEnvironmentVariable('REQUEST_METHOD');
  Path := GetEnvironmentVariable('PATH_INFO');
  MaxCGIContentLength := TransportBodyLimit(Path);
  Code := 0;
  Headers := 0;
  for I := 1 to GetEnvironmentVariableCount do
  begin
    Env := GetEnvironmentString(I);
    if StartsStr('HTTP_', Env) then
    begin
      Inc(Headers);
      if Length(Env) > 8192 then
        Code := 431;
    end;
  end;
  if Headers > SettingInt('request_headers', 64) then
    Code := 431;
  if not TryStrToInt64(GetEnvironmentVariable('CONTENT_LENGTH'), Size) then
  begin
    Size := 0;
    if GetEnvironmentVariable('CONTENT_LENGTH') <> '' then
      Code := 400;
  end;
  if (Size < 0) or (Size > MaxCGIContentLength) then
    Code := 413;
  if not SafeRequestPath(Path) then
    Code := 404;
  if (Method <> 'GET') and (Method <> 'HEAD') and (Method <> 'POST') then
    Code := 405;
  Result := Code = 0;
  if Result then
    Exit;
  Reply := 'Request refused.';
  if Code = 413 then
    Reply := 'The request body is too large.';
  Write('Status: ', Code, ' Request refused'#13#10'Content-Type: text/plain; charset=utf-8'#13#10);
  if Code = 405 then
    Write('Allow: GET, HEAD, POST'#13#10);
  Write(#13#10, Reply);
end;

end.
