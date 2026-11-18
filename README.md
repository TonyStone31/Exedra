# Exedra

A community site in one program: chat, a wiki and a forum that share the
same members, sign-in, roles and admin page. Written in Free Pascal. It
keeps its data in MariaDB, MySQL, PostgreSQL or SQLite. Turn on the parts
you want; a site can run only the chat, only the wiki, or all three.

It runs [pascal.chat](https://pascal.chat), the chat for Free Pascal,
Lazarus and Delphi developers.

## Three parts, one core

| Part | What it gives a site | Can run alone |
|---|---|---|
| **Chat** | Channels, threads, private conversations, files, an IRC side | yes |
| **Wiki** | Pages in Markdown with revisions, categories and pictures | yes |
| **Forum** | Boards, topics and posts with moderation and search | yes |

Under all three is one core: members, sign-in, roles and permissions,
the admin page, the guard, mail and backups. A member has one account
for everything, and an admin has one page to run it from.

Each part is switched on or off on the admin page. A part that is off
has no pages and no admin tabs, and its data is left alone. A site with
one part on opens straight on that part.

In the source each part is a unit named on one line of
`src/exedra.lpr`. The core uses none of them, so the program builds
and runs with any part left out.

## Getting started

[INSTALL.md](INSTALL.md) goes from nothing to a working site: build the
program, write a short config file, start it, sign up and make yourself
the admin. With SQLite there is no database server to set up.

## What it does

### Shared by every part

- Members with their own accounts, or sign-in with GitHub, GitLab,
  Google, Microsoft or Codeberg.
- The password never leaves the member's device. The browser derives a
  login secret from it, and the server only stores a hash of that.
- Roles and permissions an admin sets from a table of check boxes.
- One admin page: members, permissions, settings, look, reports, backups,
  storage and a visitors report. Each part adds its own tabs.
- A guard against scanners and password guessing, with search engine
  crawlers checked against their DNS so a real one is never blocked.
- Backup and restore of the database and files as one zip. A backup made
  on one database server goes back on another, which is also how a site
  moves between them.
- The site's words in 31 languages.

### Chat

- Channels, threads, pins, reactions, mentions, files and link previews.
- Private conversations encrypted end to end (ECDH P-256, AES-GCM). The
  server cannot read them.
- Beams: a file sent straight from one browser to another.
- Code blocks colored for Pascal and about 30 other languages.
- Slash commands, channel moderators, mute and ban.
- An IRC side, so HexChat, WeeChat or irssi can join the same channels.
- Notifications through Web Push, and mail about missed messages.
- An installable web app for phones.
- [Exedra Desktop](#exedra-desktop), a native client.

### Wiki

- Pages in Markdown with an editor, a preview and section editing.
- Revisions, categories, a link index, moving and deleting pages.
- Pictures and file pages.
- Pages in more than one language.

### Forum

- Boards in categories, topics and posts in Markdown, written with the
  wiki's editor.
- Moderation: pin, lock, move and hide.
- Search, read marks and files in posts.

The forum is the newest part. Mentions, following a topic and mail
about replies are still to come.

## Exedra Desktop

A Lazarus program for Linux, Windows and macOS that talks to any Exedra
server over the API. It gets its own repository.

## The API

Everything the web page does goes through a JSON API, so an app, a desktop
client or a bot can do the same: [docs/API.md](docs/API.md).

## Requirements

- Linux x86_64 to run the server.
- A database: MariaDB, MySQL 8 or PostgreSQL, or no server at all with
  SQLite, where the whole site is one file.
- A proxy in front for TLS (HAProxy, nginx, Caddy).
- To build: Free Pascal 3.3.1 and Lazarus, with
  [CryptoLib4Pascal](https://github.com/Xor-el/CryptoLib4Pascal),
  [HashLib4Pascal](https://github.com/Xor-el/HashLib4Pascal) and
  [SimpleBaseLib4Pascal](https://github.com/Xor-el/SimpleBaseLib4Pascal)
  (password hashing with Argon2, Web Push signing). All three are MIT
  licensed.

## The name

An exedra (say EK-seh-drah) was a part of Greek and Roman public
buildings: an open recess, often a half circle, with a bench running
along the wall. It was built for sitting down and talking. Teachers
held their classes in them and people met there to argue and trade
news. That is what this program is for.

## License

[0BSD](LICENSE). Use it for anything.
