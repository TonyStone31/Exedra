unit ChatTls;

{ The program's own requests over TLS check who answers: the certificate
  must chain to one the system trusts and name the host asked for.  The
  trusted certificates are the system's folder, or [tls] certs= in the
  site's ini. }

{$mode objfpc}{$H+}

interface

uses
  fphttpclient, sslsockets;

{ Makes Client check the servers it talks to. }
procedure CheckServers(Client: TFPHTTPClient);
{ The same for a socket opened by hand (mail). }
procedure CheckServer(Handler: TSSLSocketHandler);
function TrustedCertsFolder: string;

implementation

uses
  ChatDb;

function TrustedCertsFolder: string;
begin
  Result := '/etc/ssl/certs/';
  if Assigned(Config) then
    Result := Config.ReadString('tls', 'certs', Result);
end;

procedure CheckServers(Client: TFPHTTPClient);
begin
  Client.VerifySSLCertificate := True;
  Client.TrustedCertsDir := TrustedCertsFolder;
end;

procedure CheckServer(Handler: TSSLSocketHandler);
begin
  Handler.VerifyPeerCert := True;
  Handler.CertificateData.TrustedCertsDir := TrustedCertsFolder;
end;

end.
