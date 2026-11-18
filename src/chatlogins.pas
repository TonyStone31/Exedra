unit ChatLogins;

{ Signing in with GitHub, GitLab, Codeberg, Google or Microsoft (OAuth 2).  A provider is offered
  once the admin page (Settings, Sign-in) has its app's id and secret and it
  is switched on.  Older sites had them in the config file ([github] id= and
  secret=); they are copied into the settings once, at start.  The provider sends
  the visitor back to /_oauth/<provider>, the return address to register
  with it; Rocket.Chat uses the same, so its apps carry over.  Someone new gets an account named after their login
  there; a member already signed in links it to their account instead.  An
  account made this way has no password until its member sets one, which
  private messages need.

  A program on the member's own computer (the desktop client) signs in
  the same way: it opens /signin-with/<provider>?app=<name>&port=<n> in
  the browser and listens on 127.0.0.1:<n>; when the provider has
  answered, the browser is sent to that port with a one-time grant, which
  the program trades for an app token at /api/grant.  The token itself
  never passes through the browser. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ The providers set up in the config file, in the order to show them. }
function Providers: TStringArray;
function ProviderTitle(const Name: string): string;
{ A login from elsewhere made into a member name that is free here. }
function FreeName(const Login, Fallback: string): string;
{ Links a provider's account to a member (nothing when it is linked already). }
procedure AddLogin(const Provider, ProviderId, Login: string; UserId: integer);

implementation

uses
  Classes, StrUtils, Variants, SyncObjs, fpjson, jsonparser, httpdefs, httproute, fphttpclient,
  opensslsockets, ChatDb, SiteSql, ChatUsers, ChatGuard, ChatTls;

type
  TProvider = record
    Name, Title, AuthorizeUrl, TokenUrl, UserUrl, Scope, IdField, LoginField: string;
  end;

const
  Names: array[0..4] of string = ('github', 'gitlab', 'codeberg', 'google', 'microsoft');

{ id, secret, on or url for one provider. }
function ProviderValue(const Name, Key: string): string;
begin
  Result := Setting(Name + '_' + Key, '');
end;

function Provider(const Name: string): TProvider;
var
  GitLab, Forgejo: string;
begin
  Result.Name := Name;
  Result.Title := '';
  case Name of
    'github':
    begin
      Result.Title := 'GitHub';
      Result.AuthorizeUrl := 'https://github.com/login/oauth/authorize';
      Result.TokenUrl := 'https://github.com/login/oauth/access_token';
      Result.UserUrl := 'https://api.github.com/user';
      Result.Scope := 'read:user';
      Result.IdField := 'id';
      Result.LoginField := 'login';
    end;
    'gitlab':
    begin
      GitLab := ExcludeTrailingPathDelimiter(Setting('gitlab_url', 'https://gitlab.com'));
      Result.Title := 'GitLab';
      Result.AuthorizeUrl := GitLab + '/oauth/authorize';
      Result.TokenUrl := GitLab + '/oauth/token';
      Result.UserUrl := GitLab + '/api/v4/user';
      Result.Scope := 'read_user';
      Result.IdField := 'id';
      Result.LoginField := 'username';
    end;
    // Codeberg runs Forgejo; codeberg_url points it at another Forgejo or a Gitea.
    'codeberg':
    begin
      Forgejo := ExcludeTrailingPathDelimiter(Setting('codeberg_url', 'https://codeberg.org'));
      Result.Title := 'Codeberg';
      Result.AuthorizeUrl := Forgejo + '/login/oauth/authorize';
      Result.TokenUrl := Forgejo + '/login/oauth/access_token';
      Result.UserUrl := Forgejo + '/api/v1/user';
      Result.Scope := 'read:user';
      Result.IdField := 'id';
      Result.LoginField := 'login';
    end;
    'google':
    begin
      Result.Title := 'Google';
      Result.AuthorizeUrl := 'https://accounts.google.com/o/oauth2/v2/auth';
      Result.TokenUrl := 'https://oauth2.googleapis.com/token';
      Result.UserUrl := 'https://openidconnect.googleapis.com/v1/userinfo';
      Result.Scope := 'openid profile';
      Result.IdField := 'sub';
      Result.LoginField := 'name';
    end;
    // Personal and work accounts alike ("common").
    'microsoft':
    begin
      Result.Title := 'Microsoft';
      Result.AuthorizeUrl := 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
      Result.TokenUrl := 'https://login.microsoftonline.com/common/oauth2/v2.0/token';
      Result.UserUrl := 'https://graph.microsoft.com/oidc/userinfo';
      Result.Scope := 'openid profile';
      Result.IdField := 'sub';
      Result.LoginField := 'name';
    end;
  end;
end;

{ Microsoft waits until an admin switches it on. }
function DefaultOn(const Name: string): string;
begin
  Result := '1';
  if Name = 'microsoft' then
    Result := '0';
end;

function Ready(const Name: string): boolean;
begin
  Result := (Provider(Name).Title <> '') and (Setting(Name + '_on', DefaultOn(Name)) = '1') and (ProviderValue(Name, 'id') <> '') and (ProviderValue(Name, 'secret') <> '');
end;

function Providers: TStringArray;
var
  Name: string;
begin
  Result := [];
  for Name in Names do
    if Ready(Name) then
      Result := Concat(Result, [Name]);
end;

function ProviderTitle(const Name: string): string;
begin
  Result := Provider(Name).Title;
end;

function ReturnUrl(ARequest: TRequest; const Name: string): string;
begin
  Result := Setting('url', '');
  if Result = '' then
    if Setting('https', '0') = '1' then
      Result := 'https://' + ARequest.Host
    else
      Result := 'http://' + ARequest.Host;
  Result := ExcludeTrailingPathDelimiter(Result) + '/_oauth/' + Name;
end;

{ ---- grants for programs on the member's computer ---- }

var
  GrantLock: TCriticalSection;
  Grants: TStringList;   // code=token|expiry, two minutes each

procedure PruneGrants;
var
  I: integer;
  Parts: TStringArray;
begin
  for I := Grants.Count - 1 downto 0 do
  begin
    Parts := Grants.ValueFromIndex[I].Split(['|']);
    if (Length(Parts) < 2) or (StrToFloatDef(Parts[1], 0) < Now) then
      Grants.Delete(I);
  end;
end;

function NewGrant(const Token: string): string;
begin
  Result := RandomHex(16);
  GrantLock.Enter;
  try
    PruneGrants;
    Grants.Values[Result] := Token + '|' + FloatToStr(Now + 2 / MinsPerDay);
  finally
    GrantLock.Leave;
  end;
end;

{ The token behind a grant, once; '' when there is none or it is used. }
function TakeGrant(const Code: string): string;
var
  I: integer;
begin
  Result := '';
  GrantLock.Enter;
  try
    PruneGrants;
    I := Grants.IndexOfName(Code);
    if I >= 0 then
    begin
      Result := Grants.ValueFromIndex[I].Split(['|'])[0];
      Grants.Delete(I);
    end;
  finally
    GrantLock.Leave;
  end;
end;

{ POST /api/grant  code; answers token, once }
procedure GiveGrant(ARequest: TRequest; AResponse: TResponse);
var
  Token: string;
begin
  if not TokenTry(ARequest, AResponse) then
    Exit;
  Token := TakeGrant(ARequest.ContentFields.Values['code']);
  if Token = '' then
  begin
    Strike(ClientIp(ARequest), 'password');
    SendText(AResponse, 404, 'That sign-in is not waiting here, or was taken already.');
  end
  else
    SendJSON(AResponse, TJSONObject.Create(['token', Token]));
end;

{ GET /api/providers  the sign-ins offered here, for a program to show }
procedure ShowProviders(ARequest: TRequest; AResponse: TResponse);
var
  List: TJSONArray;
  Name: string;
begin
  List := TJSONArray.Create;
  for Name in Providers do
    List.Add(TJSONObject.Create(['name', Name, 'title', ProviderTitle(Name)]));
  SendJSON(AResponse, List);
end;

{ Where a program waiting on the member's computer is told the outcome,
  from the cookie GoSignIn set; '' for a browser sign-in. }
function AppReturn(ARequest: TRequest): string;
var
  Parts: TStringArray;
begin
  Result := '';
  Parts := ARequest.CookieFields.Values['oauthapp'].Split(['|']);
  if (Length(Parts) = 2) and (StrToIntDef(Parts[1], 0) > 0) then
    Result := 'http://127.0.0.1:' + Parts[1] + '/';
end;

function AppName(ARequest: TRequest): string;
begin
  Result := ARequest.CookieFields.Values['oauthapp'].Split(['|'])[0];
end;

{ GET /signin-with/:provider  off to the provider, with a random state that must
  come back in the cookie it is also kept in.  With app and port, a program
  on this computer is waiting for the outcome (see the unit's note). }
procedure GoSignIn(ARequest: TRequest; AResponse: TResponse);
var
  P: TProvider;
  State: string;
begin
  P := Provider(ARequest.RouteParams['provider']);
  if not Ready(P.Name) then
  begin
    SendText(AResponse, 404, 'No sign-in by that name here.');
    Exit;
  end;
  State := RandomHex(16);
  with AResponse.Cookies.Add do
  begin
    Name := 'oauth';
    Value := State;
    Path := '/';
    Expires := NowUTC + 10 / MinsPerDay;
    HttpOnly := True;
    SameSite := ssLax;
    Secure := Setting('https', '0') = '1';
  end;
  // the page to come back to once signed in, a page on this site only
  with AResponse.Cookies.Add do
  begin
    Name := 'oauthback';
    Value := HTTPEncode(LocalReturn(ARequest.QueryFields.Values['return']));
    Path := '/';
    Expires := NowUTC + 10 / MinsPerDay;
    HttpOnly := True;
    SameSite := ssLax;
    Secure := Setting('https', '0') = '1';
  end;
  with AResponse.Cookies.Add do
  begin
    Name := 'oauthapp';
    Value := '';
    if (ARequest.QueryFields.Values['app'] <> '') and (StrToIntDef(ARequest.QueryFields.Values['port'], 0) > 0) then
      Value := StringReplace(Copy(ARequest.QueryFields.Values['app'], 1, 60), '|', ' ', [rfReplaceAll]) + '|' +
        IntToStr(StrToIntDef(ARequest.QueryFields.Values['port'], 0));
    Path := '/';
    Expires := NowUTC + 10 / MinsPerDay;
    HttpOnly := True;
    SameSite := ssLax;
    Secure := Setting('https', '0') = '1';
  end;
  AResponse.SendRedirect(P.AuthorizeUrl + '?response_type=code&client_id=' + HTTPEncode(ProviderValue(P.Name, 'id')) + '&redirect_uri=' +
    HTTPEncode(ReturnUrl(ARequest, P.Name)) + '&scope=' + HTTPEncode(P.Scope) + '&state=' + State);
end;

{ Trades the code for a token, and the token for who it belongs to.  False
  when anything on the way fails; the log says what. }
function WhoIsIt(ARequest: TRequest; const P: TProvider; out Id, Login: string): boolean;
var
  Client: TFPHTTPClient;
  Form: TStringList;
  Answer: TJSONData;
  Token: string;
begin
  Result := False;
  Id := '';
  Login := '';
  Client := TFPHTTPClient.Create(nil);
  CheckServers(Client);
  Form := TStringList.Create;
  Answer := nil;
  try
    try
      Client.ConnectTimeout := 5000;
      Client.IOTimeout := 8000;
      Client.AddHeader('Accept', 'application/json');
      Client.AddHeader('User-Agent', Setting('name', 'Exedra') + ' chat server');
      Form.AddPair('client_id', ProviderValue(P.Name, 'id'));
      Form.AddPair('client_secret', ProviderValue(P.Name, 'secret'));
      Form.AddPair('code', ARequest.QueryFields.Values['code']);
      Form.AddPair('redirect_uri', ReturnUrl(ARequest, P.Name));
      Form.AddPair('grant_type', 'authorization_code');
      Answer := GetJSON(Client.FormPost(P.TokenUrl, Form));
      Token := TJSONObject(Answer).Get('access_token', '');
      FreeAndNil(Answer);
      if Token = '' then
        raise Exception.Create('no access token');
      Client.AddHeader('Authorization', 'Bearer ' + Token);
      Answer := GetJSON(Client.Get(P.UserUrl));
      Id := TJSONObject(Answer).Get(P.IdField, '');
      if Id = '' then
        Id := IntToStr(TJSONObject(Answer).Get(P.IdField, int64(0)));
      Login := TJSONObject(Answer).Get(P.LoginField, '');
      Result := (Id <> '') and (Id <> '0');
    except
      on E: Exception do
        Log('Sign-in with ' + P.Title + ': ' + E.Message);
    end;
  finally
    Answer.Free;
    Form.Free;
    Client.Free;
  end;
end;

function FreeName(const Login, Fallback: string): string;
var
  Base: string;
  C: char;
  N: integer;
begin
  Base := '';
  for C in Login do
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.'] then
      Base := Base + C;
  Base := Copy(Base, 1, 20);
  while Pos('..', Base) > 0 do
    Base := StringReplace(Base, '..', '.', [rfReplaceAll]);
  Base := Base.Trim(['.']);
  if Length(Base) < 2 then
    Base := Fallback;
  Result := Base;
  N := 1;
  while MemberExists(Result) or (NameRefusal(Result) <> '') do
  begin
    Inc(N);
    Result := Base + IntToStr(N);
  end;
end;

procedure AddLogin(const Provider, ProviderId, Login: string; UserId: integer);
begin
  Exec(SqlInsertIgnore('logins', 'provider, provider_id, login, user_id', ':p, :i, :l, :u'),
    [Provider, ProviderId, Copy(Login, 1, 100), UserId]);
end;

{ GET /_oauth/:provider?code=&state= }
procedure ComeBack(ARequest: TRequest; AResponse: TResponse);
var
  P: TProvider;
  Me: TMember;
  Id, Login, Back: string;
  UserId: integer;
begin
  CheckConnection;
  Back := AppReturn(ARequest);
  if not TokenTry(ARequest, AResponse) then
    Exit;
  P := Provider(ARequest.RouteParams['provider']);
  if not Ready(P.Name) or (ARequest.QueryFields.Values['state'] = '') or (ARequest.QueryFields.Values['state'] <> ARequest.CookieFields.Values['oauth']) or
    not WhoIsIt(ARequest, P, Id, Login) then
  begin
    Strike(ClientIp(ARequest), 'password');
    if Back <> '' then
      AResponse.SendRedirect(Back + '?failed=1')
    else
      AResponse.SendRedirect('/signin?failed=1');
    Exit;
  end;
  Me := CurrentMember(ARequest);
  UserId := IntValue('SELECT user_id FROM logins WHERE provider = :p AND provider_id = :i', [P.Name, Id]);
  if Me.Id > 0 then
  begin
    if UserId = 0 then
      AddLogin(P.Name, Id, Login, Me.Id);
    // Linked to someone else already: leave it where it is.  A program
    // waiting on this computer gets the member the browser is signed in as.
    if Back <> '' then
      AResponse.SendRedirect(Back + '?grant=' + NewGrant(NewSession(Me.Id, 'app', AppName(ARequest), AppSessionDays)))
    else
      AResponse.SendRedirect('/u/' + HTTPEncode(Me.Name));
    Exit;
  end;
  if UserId = 0 then
  begin
    if TooManySignups(ClientIp(ARequest)) or not AllowAttempt(ClientIp(ARequest), 'signuptry', SettingInt('signuptry_address', 10), 1) then
    begin
      SendText(AResponse, 429, 'Too many new accounts from here. Try again later.');
      Exit;
    end;
    if Setting('registration', 'open') <> 'open' then
    begin
      if Back <> '' then
        AResponse.SendRedirect(Back + '?failed=closed')
      else
        AResponse.SendRedirect('/signin?failed=closed');
      Exit;
    end;
    UserId := AddMember(FreeName(Login, P.Name), '', '', '', '', True);
    NoteTry(ClientIp(ARequest), 'signup');
    AddLogin(P.Name, Id, Login, UserId);
  end;
  if Back <> '' then
  begin
    // The program gets its token through the grant; the browser is not
    // signed in by this.
    AResponse.SendRedirect(Back + '?grant=' + NewGrant(NewSession(UserId, 'app', AppName(ARequest), AppSessionDays)));
    Exit;
  end;
  StartWebSession(AResponse, UserId);
  Back := LocalReturn(HTTPDecode(ARequest.CookieFields.Values['oauthback']));
  if (Back = '') or StartsText('/signin', Back) then
    Back := '/';
  AResponse.SendRedirect(Back);
end;

{ GET /api/logins  the providers here, and which the member has linked }
procedure ShowLogins(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
  List: TJSONArray;
  Name: string;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  List := TJSONArray.Create;
  for Name in Providers do
    List.Add(TJSONObject.Create(['name', Name, 'title', ProviderTitle(Name), 'login',
      VarToStr(Value('SELECT login FROM logins WHERE provider = :p AND user_id = :u', [Name, Me.Id]))]));
  SendJSON(AResponse, TJSONObject.Create(['providers', List, 'password', VarToStr(Value('SELECT auth_hash FROM users WHERE id = :u', [Me.Id])) <> '']));
end;

{ POST /api/logins  unlink=provider, unless it is the only way in left }
procedure Unlink(ARequest: TRequest; AResponse: TResponse);
var
  Me: TMember;
begin
  CheckConnection;
  if not NeedMember(ARequest, AResponse, Me) then
    Exit;
  if (VarToStr(Value('SELECT auth_hash FROM users WHERE id = :u', [Me.Id])) = '') and (IntValue('SELECT COUNT(*) FROM logins WHERE user_id = :u', [Me.Id]) <= 1) then
    SendText(AResponse, 409, 'That is your only way in. Set a password first.')
  else
  begin
    Exec('DELETE FROM logins WHERE user_id = :u AND provider = :p',
      [Me.Id, ARequest.ContentFields.Values['unlink']]);
    SendText(AResponse, 200, 'ok');
  end;
end;

{ A site set up before the admin page had these: its config file's apps
  become settings, once. }
procedure TakeIniApps;
var
  Name: string;
begin
  for Name in Names do
    if (Setting(Name + '_id', '') = '') and (Config.ReadString(Name, 'id', '') <> '') then
    begin
      SaveSetting(Name + '_id', Config.ReadString(Name, 'id', ''));
      SaveSetting(Name + '_secret', Config.ReadString(Name, 'secret', ''));
      Log('Sign-in with ' + Name + ': moved from the config file to the settings');
    end;
  if (Setting('gitlab_url', '') = '') and (Config.ReadString('gitlab', 'url', '') <> '') then
    SaveSetting('gitlab_url', Config.ReadString('gitlab', 'url', ''));
end;

initialization
  GrantLock := TCriticalSection.Create;
  Grants := TStringList.Create;
  RegisterStartup(@TakeIniApps);
  RegisterSetting('github_on', 'Offer sign-in with GitHub', '1', 'yesno', 'Sign-in');
  RegisterSetting('github_id', 'GitHub app: client id', '', 'text', 'Sign-in');
  RegisterSetting('github_secret', 'GitHub app: client secret', '', 'secret', 'Sign-in');
  RegisterSetting('gitlab_on', 'Offer sign-in with GitLab', '1', 'yesno', 'Sign-in');
  RegisterSetting('gitlab_id', 'GitLab app: application id', '', 'text', 'Sign-in');
  RegisterSetting('gitlab_secret', 'GitLab app: secret', '', 'secret', 'Sign-in');
  RegisterSetting('gitlab_url', 'GitLab address (another GitLab than gitlab.com)', 'https://gitlab.com', 'text',
    'Sign-in');
  RegisterSetting('codeberg_on', 'Offer sign-in with Codeberg', '1', 'yesno', 'Sign-in');
  RegisterSetting('codeberg_id', 'Codeberg app: client id', '', 'text', 'Sign-in');
  RegisterSetting('codeberg_secret', 'Codeberg app: client secret', '', 'secret', 'Sign-in');
  RegisterSetting('codeberg_url', 'Codeberg address (another Forgejo or Gitea than codeberg.org)', 'https://codeberg.org',
    'text', 'Sign-in');
  RegisterSetting('google_on', 'Offer sign-in with Google', '1', 'yesno', 'Sign-in');
  RegisterSetting('google_id', 'Google OAuth client: client id', '', 'text', 'Sign-in');
  RegisterSetting('google_secret', 'Google OAuth client: client secret', '', 'secret', 'Sign-in');
  RegisterSetting('microsoft_on', 'Offer sign-in with Microsoft', '0', 'yesno', 'Sign-in');
  RegisterSetting('microsoft_id', 'Microsoft app: application (client) id', '', 'text', 'Sign-in');
  RegisterSetting('microsoft_secret', 'Microsoft app: client secret value', '', 'secret', 'Sign-in');
  RegisterTable('CREATE TABLE IF NOT EXISTS logins (' + ' provider VARCHAR(10) NOT NULL, provider_id VARCHAR(64) NOT NULL,' +
    ' login VARCHAR(100) NOT NULL DEFAULT '''', user_id INT NOT NULL,' + ' created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,' +
    ' PRIMARY KEY (provider, provider_id), INDEX (user_id)) CHARACTER SET utf8mb4');
  HTTPRouter.RegisterRoute('/signin-with/:provider', rmGet, @GoSignIn);
  HTTPRouter.RegisterRoute('/_oauth/:provider', rmGet, @ComeBack);
  HTTPRouter.RegisterRoute('/api/providers', rmGet, @ShowProviders);
  HTTPRouter.RegisterRoute('/api/grant', rmPost, @GiveGrant);
  HTTPRouter.RegisterRoute('/api/logins', rmGet, @ShowLogins);
  HTTPRouter.RegisterRoute('/api/logins', rmPost, @Unlink);

finalization
  Grants.Free;
  GrantLock.Free;

end.
