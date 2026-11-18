program exedra;

{ Exedra, a chat server: web pages, IRC, private messages, files.  One
  program that runs as its own web server, or as a CGI program when built
  with -dCGI.  The config file is exedra.ini beside the program, or the
  file named on the command line.

  ChatServer is the shared core: members, the admin page, the pages every
  site has.  Each part of the site is one more unit in the uses line below
  (ChatPart is the chat, Wiki the wiki) and plugs itself in; leave a part's
  unit out and the program is built without it.  WikiChat is what the wiki
  and the chat share; it goes when either does.

  exedra [config] --admin Name   makes that member an admin and stops.
  exedra [config] --password-link Name   prints a one-time link that lets
  that member set a new password. }

{$mode objfpc}{$H+}

uses
  {$ifdef unix} {$ifndef CGI} cthreads, {$endif} cwstring, {$endif} ChatPart,
  Wiki,
  WikiChat,
  Forum,
  ChatServer;

begin
  RunServer;
end.
