# Installing Exedra

This goes from nothing to a working site. The short version: build one
program, put it in a folder with its page files and a config file, start
it, sign up, and make yourself the admin.

- [What Exedra is made of](#what-exedra-is-made-of)
- [What you need](#what-you-need)
- [1. Build the program](#1-build-the-program)
- [2. Make the site folder](#2-make-the-site-folder)
- [3. Write the config file](#3-write-the-config-file)
- [4. Start it and become the admin](#4-start-it-and-become-the-admin)
- [5. Choose the parts](#5-choose-the-parts)
- [6. Put it on the internet](#6-put-it-on-the-internet)
- [7. Run it as a service](#7-run-it-as-a-service)
- [8. Mail](#8-mail)
- [9. Sign-in with GitHub and others](#9-sign-in-with-github-and-others)
- [10. IRC](#10-irc)
- [11. Backups, moving and upgrading](#11-backups-moving-and-upgrading)
- [When something is wrong](#when-something-is-wrong)

## What Exedra is made of

Exedra is one program with three parts on a shared core.

| | What it is | Where it lives on the site |
|---|---|---|
| **Core** | Members, sign-in, roles and permissions, the admin page, the guard, the visitors report, mail, backups. Always there. | `/signin`, `/admin`, `/u/<name>` |
| **Chat** | Channels, threads, private conversations, files, the IRC side. | `/p/<channel>`, `/dm` |
| **Wiki** | Pages in Markdown with revisions, categories and pictures. | `/wiki` |
| **Forum** | Boards, topics and posts. | `/forum` |

Every part uses the same members and the same admin page. Each part can
be turned on or off, in the config file or on the admin page. A part that
is off has no pages, no admin tabs and no entry in the top bar. Its
tables are left alone, so turning it back on brings everything back.

With one part on, the site's front page opens straight on that part. With
more than one, the front page is a home page that links to each.

## What you need

- **A Linux machine, x86_64.** A small VPS is enough.
- **A database.** One of:
  - **SQLite.** No database server. The whole site is one file. The
    easiest start, and fine for a small community.
  - **MariaDB** or **MySQL 8**.
  - **PostgreSQL**.
- **Libraries the program loads at run time:** OpenSSL, and the client
  library of your database. On Debian or Ubuntu:

  ```sh
  sudo apt install libssl3 libsqlite3-0      # SQLite
  sudo apt install libssl3 libmariadb3       # MariaDB or MySQL
  sudo apt install libssl3 libpq5            # PostgreSQL
  ```

- **To build:** Free Pascal 3.3.1 (the main branch) and Lazarus built
  with it. [fpcupdeluxe](https://github.com/LongDirtyAnimAlf/fpcupdeluxe)
  installs both, choose "trunk" for each. The released Free Pascal 3.2
  is too old, because the Markdown and code coloring units Exedra
  uses are newer than it.
- **Three Pascal libraries**, all MIT licensed:
  [HashLib4Pascal](https://github.com/Xor-el/HashLib4Pascal),
  [SimpleBaseLib4Pascal](https://github.com/Xor-el/SimpleBaseLib4Pascal) and
  [CryptoLib4Pascal](https://github.com/Xor-el/CryptoLib4Pascal).
  They do the password hashing and sign the push notifications.
- **For a public site:** a domain name and a proxy in front that does
  TLS (Caddy, nginx or HAProxy). See step 6.

You build on any machine with Lazarus and copy the result to the
server. The server itself needs no compiler.

## 1. Build the program

Get the source and the three libraries:

```sh
git clone https://github.com/TonyStone31/Exedra.git
git clone https://github.com/Xor-el/HashLib4Pascal.git
git clone https://github.com/Xor-el/SimpleBaseLib4Pascal.git
git clone https://github.com/Xor-el/CryptoLib4Pascal.git
```

Tell Lazarus where the libraries are. This is done once:

```sh
lazbuild --add-package-link HashLib4Pascal/HashLib/src/Packages/FPC/HashLib4PascalPackage.lpk
lazbuild --add-package-link SimpleBaseLib4Pascal/SimpleBaseLib/src/Packages/FPC/SimpleBaseLib4PascalPackage.lpk
lazbuild --add-package-link CryptoLib4Pascal/CryptoLib/src/Packages/FPC/CryptoLib4PascalPackage.lpk
```

Build:

```sh
lazbuild Exedra/src/exedra.lpi
```

The program is now at `Exedra/bin/exedra`. The first build takes
about a minute because the crypto library is large.

## 2. Make the site folder

The site is a folder that holds the program, its page files and its
config file. The program writes its own data under `data/` in the same
folder.

```sh
sudo mkdir -p /opt/exedra
sudo cp Exedra/bin/exedra /opt/exedra/
sudo cp -r Exedra/site/. /opt/exedra/
sudo cp Exedra/exedra.ini.example /opt/exedra/exedra.ini
```

The folder then looks like this:

```
/opt/exedra/
  exedra          the program
  exedra.ini      the config file
  static/         scripts, styles and pictures
  templates/      the pages
  lang/           the site's words in 31 languages
  data/           made by the program: files, backups, logs,
                  and the database when it is SQLite
```

Give it a user of its own, so the site does not run as root:

```sh
sudo useradd --system --home /opt/exedra --shell /usr/sbin/nologin exedra
sudo chown -R exedra:exedra /opt/exedra
sudo chmod 600 /opt/exedra/exedra.ini
```

## 3. Write the config file

Edit `/opt/exedra/exedra.ini`. The sample has every setting with a
comment. A small site on SQLite needs only this:

```ini
[site]
name=My Community
url=http://127.0.0.1:8099
port=8099
address=127.0.0.1
files=/opt/exedra

[database]
server=sqlite
file=/opt/exedra/data/site.db
```

`address=127.0.0.1` means only this machine can reach it, which is right
when a proxy sits in front. To try it from another computer on your own
network without a proxy, leave `address` out and set `url` to the
machine's address.

### MariaDB or MySQL instead

Make an empty database and a user for it:

```sql
CREATE DATABASE exedra CHARACTER SET utf8mb4;
CREATE USER 'exedra'@'localhost' IDENTIFIED BY 'a long password';
GRANT ALL ON exedra.* TO 'exedra'@'localhost';
```

```ini
[database]
host=127.0.0.1
port=3306
name=exedra
user=exedra
password=a long password
```

For MySQL 8 add `client=mysql80` and, when it is not found on its own,
`library=` with the path of `libmysqlclient.so`.

### PostgreSQL instead

```sh
sudo -u postgres createuser --pwprompt exedra
sudo -u postgres createdb --owner exedra --encoding UTF8 exedra
```

```ini
[database]
server=postgres
host=127.0.0.1
port=5432
name=exedra
user=exedra
password=a long password
```

Whichever you choose, the program makes its own tables at the first
start. There is no schema file to load. You can change your mind later:
a backup made on one database goes back on any other (step 11).

## 4. Start it and become the admin

```sh
cd /opt/exedra
sudo -u exedra ./exedra
```

It reads `exedra.ini` from its own folder. To use another file, name
it: `./exedra /etc/exedra.ini`.

Open `http://127.0.0.1:8099` in a browser and **sign up**. The first
account is an ordinary member like any other. Make it the admin from a
second terminal:

```sh
cd /opt/exedra
sudo -u exedra ./exedra --admin YourName
```

It answers `YourName is an admin now.` Reload the page and open
`/admin`. From here on, everything is set on the admin page: the site's
name and look, who may do what, new accounts open or closed, limits,
and the parts.

## 5. Choose the parts

A new site starts with the chat and the wiki on and the forum off.

On the admin page, **Settings**, group **Parts**: a yes or no for each
part. The change takes effect at once.

The same switches work in the config file, for a site that should start
a certain way before anyone has signed in:

```ini
[site]
chat=1
wiki=1
forum=1
```

A value saved on the admin page wins over the config file.

Some ways to set a site up:

| You want | Turn on | The front page |
|---|---|---|
| A wiki and nothing else | wiki | opens the wiki's main page |
| A forum and nothing else | forum | opens the forum |
| A chat for a team or a project | chat | the home page, or a channel when `start_room` is set |
| A whole community site | all three | the home page, with links to each |

Each part adds its own tabs to the admin page (Channels for the chat,
Forum boards for the forum) and its own settings groups.

## 6. Put it on the internet

Exedra speaks plain HTTP. A proxy in front holds the certificate. The
proxy must pass WebSocket connections through, because the live updates
use one at `/api/live`.

Tell Exedra it is behind TLS and what its public address is:

```ini
[site]
url=https://community.example.com
https=1
address=127.0.0.1
proxies=127.0.0.1
```

`proxies` lists the addresses whose `X-Forwarded-For` header is
believed. Leave it at the proxy's own address. Without it every visitor
would seem to come from the proxy, and the guard would block the proxy.

**Caddy** gets and renews the certificate by itself. The whole
`Caddyfile`:

```
community.example.com {
    reverse_proxy 127.0.0.1:8099
}
```

**nginx**, with a certificate from certbot:

```nginx
server {
    listen 443 ssl;
    server_name community.example.com;
    ssl_certificate     /etc/letsencrypt/live/community.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/community.example.com/privkey.pem;
    client_max_body_size 40m;

    location / {
        proxy_pass http://127.0.0.1:8099;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1h;
    }
}
```

Restart Exedra after changing the config file.

## 7. Run it as a service

Copy the sample unit and start it:

```sh
sudo cp Exedra/exedra.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now exedra
systemctl status exedra
```

The unit runs `/opt/exedra/exedra` as the user `exedra` and
starts it again if it stops. Edit the paths in it if yours differ.

## 8. Mail

Mail is optional. With it, new members confirm their address, a
forgotten password gets a link, and members hear about messages they
missed. Exedra signs in to a mailbox over TLS (port 465):

```ini
[mail]
host=mail.example.com
port=465
user=community@example.com
password=the mailbox password
from=community@example.com
name=My Community
reports_to=you@example.com
```

`reports_to` is where reports from members go. Without a `[mail]`
section nothing is sent and the site works all the same.

Without mail, an admin can still help someone who forgot their
password:

```sh
sudo -u exedra ./exedra --password-link TheirName
```

It prints a one-time link to send them.

## 9. Sign-in with GitHub and others

Members can sign in with GitHub, GitLab, Codeberg, Google or Microsoft.
Each one needs an OAuth app that you register with that provider. Give
the provider this return address:

```
https://community.example.com/_oauth/github
```

with `gitlab`, `codeberg`, `google` or `microsoft` in place of `github`.
Then put the app's id and secret on the admin page, **Settings**, group
**Sign-in**. A provider shows on the sign-in page once it has both.

A self-hosted GitLab, Forgejo or Gitea works too: set its address in
the same group.

## 10. IRC

The chat can also be an IRC server on the same channels and members, so
people can join from HexChat, WeeChat or irssi.

```ini
[irc]
tls_port=6697
cert=/etc/letsencrypt/live/community.example.com/fullchain.pem
key=/etc/letsencrypt/live/community.example.com/privkey.pem
public_port=6697
```

The user `exedra` must be able to read the two files. Open the port
in the firewall. The site's `/irc` page then tells members how to set up
their client. Without an `[irc]` section there is no IRC side.

## 11. Backups, moving and upgrading

**Backups.** On the admin page, **Backup** makes one zip with the whole
site: every table, the members' files and the config file. It can be
downloaded, checked and restored there. From the command line, for a
nightly cron job:

```sh
sudo -u exedra /opt/exedra/exedra --backup
sudo -u exedra /opt/exedra/exedra --backup --pictures --logs
```

Backups are kept in `/opt/exedra/data/backups`. Copy them to another
machine. The zip holds the config file with the database password, so
keep it as safe as the site.

**Moving to another machine, or another database.** Install Exedra
on the new machine as above, with a config file that names an empty
database. Then, with the service stopped:

```sh
sudo -u exedra /opt/exedra/exedra --restore /path/to/site-backup.zip
sudo systemctl start exedra
```

A backup holds rows, not table definitions, so one made on MariaDB goes
back on PostgreSQL or SQLite and the other way around.

**Upgrading.** Make a backup. Build the new version, stop the service,
replace the program and the `static`, `templates` and `lang` folders,
and start it again. The program upgrades its own tables at start.

```sh
sudo systemctl stop exedra
sudo cp Exedra/bin/exedra /opt/exedra/
sudo cp -r Exedra/site/. /opt/exedra/
sudo chown -R exedra:exedra /opt/exedra
sudo systemctl start exedra
```

Your `exedra.ini` and `data/` are not touched by this.

## When something is wrong

- **It does not start.** Run it by hand as in step 4 and read what it
  prints. A missing library is named there, and so is a database it
  cannot reach.
- **The page loads without styles.** `files=` in the config does not
  point at the folder that holds `static/`, `templates/` and `lang/`.
- **Signing in fails behind the proxy.** `https=1` and `url=` must match
  the address people type. Sign-in cookies are marked for TLS only when
  `https=1`.
- **Everyone is blocked at once.** `proxies=` does not list the proxy,
  so all visitors look like one address.
- **Messages only show after a reload.** The proxy does not pass
  WebSocket connections. The site still works by polling, only slower.
- **The log.** `journalctl -u exedra` when run as a service. The
  access logs are in `data/logs`, and the admin page's Visitors tab
  reads them.
