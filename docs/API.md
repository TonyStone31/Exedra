# The Exedra API

Everything the web page does goes through this API, so an app, a desktop
client or a bot can do the same. Answers are JSON unless they say
otherwise; refusals are plain text with a 4xx code, in words a person can
read.

## Signing in

The password never leaves the device. From the name and password a client
derives two keys:

1. `PBKDF2-SHA256(password, salt = "beginend:" + lowercase(name), 600000 rounds)` gives 32 bytes. (beginend was the program's first name; the salt keeps it so passwords made then still work.)
2. HKDF-SHA256 over those bytes (salt 32 zero bytes, info `sign in`) gives the login secret, sent as 64 hex digits (`auth`).
3. HKDF-SHA256 the same way with info `wrap` gives the AES-GCM key that wraps the member's private key.

`static/keys.js` is the reference: a client has to derive exactly what it
derives, or the member's private messages cannot be opened.

Before signing in or opening a wrapped key, get `/api/auth-name?name=` and
use its `name` in the password salt. The account's current name still goes
in the sign-in request. Signup and a new password use the current name as
the salt. A rename keeps the previous salt so the password keeps working.

| Request | Fields | Answer |
|---|---|---|
| `POST /api/signup` | name, auth, pub (the public ECDH P-256 key), wrapped (the private key, wrapped), app | name, token when app was sent |
| `POST /api/signin` | name, auth, app | name, wrapped, token when app was sent |
| `GET /api/auth-name?name=` | | name to use in the password salt, unchanged by a member rename |
| `POST /api/signout` | | ok |
| `GET /api/me` | | name, key_name (the stable identity for locked messages), roles, banned, can (site permissions), avatar, away |

A web page gets a cookie. An app sends `app=<a name for the device>` and
gets a token instead, good for a year. Send it on every request:

    Authorization: Bearer <token>

Signing in with GitHub, GitLab and the others from an app: `GET
/api/providers` lists what the site offers (`name`, `title`). The app
listens on a port of 127.0.0.1 and opens
`/signin-with/<name>?app=<its name>&port=<port>` in the browser; when
the provider has answered, the browser is sent to
`http://127.0.0.1:<port>/?grant=<code>` (or `?failed=1`, or
`?failed=closed` when new accounts are closed). `POST /api/grant` with
that `code`, within two minutes and once, answers the app token. A
member already signed in on the web links the login to their account
and the app gets that account.

Members can also make tokens for bots on their profile page (`GET/POST
/api/tokens`). A bot is an ordinary account; an admin can give it the
`bot` role so it shows a badge.

## Staying current

1. Connect a WebSocket to `/api/live` (send the cookie or the
   Authorization header). The first message is `{"t":"hello","id":"..."}`.
2. Send that id as `live` with every `GET /api/sync`. The server then
   knows which channel this client shows.
3. Send any text every 25 seconds, or the server closes the connection
   after 90.
4. When a ring arrives, ask `/api/sync`. Rings never carry content:

| Ring | Meaning |
|---|---|
| `{"t":"room","room":"lobby"}` | something changed in that channel |
| `{"t":"typing","room":"lobby","name":"x"}` | x is typing in the channel this client shows |
| `{"t":"me"}` | something for this member: a mention, an invite |
| `{"t":"dm","from":"x"}` | a private message from x (or one this member sent from another device); with `"deleted": id` that message was taken back, with `"gone": true` the whole conversation |
| `{"t":"names"}` | a member was renamed; refresh member and room lists and cached private-message identities |

Without a live connection (a site run as CGI has none), ask `/api/sync`
every few seconds instead.

`GET /api/sync?room=&since=&thread=&read=&rooms=1&live=` answers with
`rev`, then what changed since `since`: `messages` in the channel, `thread`
(the open thread), `typing`, `here`, and with `rooms=1` the sidebar
(`rooms` with unread and mention counts, `owner`, whether this member
opened the channel, and `notify`; `dms`). Keep the highest `rev`
seen minus three seconds as the next `since`, and replace messages by `id`
when a newer `rev` arrives. `read` marks the channel read up to a message id.

## Channels and messages

| Request | Notes |
|---|---|
| `GET /api/rooms` | the member's followed channels (public channels for guests) |
| `GET /api/room?slug=` | one channel: kind, topic, owner, private, following, can_start, why_not, can (what this member may do there), and whatever units added on top put there; opening a channel makes it the one `/` brings the member back to |
| `GET /api/room/members?room=` | a private channel's members, or who holds a role in a public one: name, avatar, roles, owner, `away`, and `online` (seen on some page in the last two minutes) |
| `POST /api/room/create` | slug, topic, private (1 or 0) |
| `POST /api/follow` | room, on (1 or 0); off is leaving the channel |
| `POST /api/follow/notify` | room, mode: `all`, `mentions` or `none`. How much a followed channel may bother the member. Silenced (`none`) means no push and no mail about mentions there, and the page shows no badge; `mentions` shows the mention badge alone. The sidebar carries each room's `notify`. |
| `POST /api/room/delete` | slug: a private channel, by its owner (the room permission `delete-channel`) or a member with `manage-private`; everything in it goes and its members get the ring `gone`. A public channel is refused. |
| `POST /api/topic` | room, topic |
| `POST /api/typing` | room |
| `GET /api/messages?room=&before=` | 50 messages, newest first, before an id |
| `GET /api/thread?id=` | a message and its replies |
| `GET /api/pins?room=` | |
| `GET /api/search?q=&room=` | words of three letters or more, anywhere the member may read |
| `POST /api/post` | room, parent (a thread), body, files. Answers id, info (text for this member only), go (a page to open, after /join) |
| `POST /api/edit` | id, body |
| `POST /api/delete` | id |
| `POST /api/react` | id, r (0 to 5: 👍 ❤️ 😂 🎉 🤔 👎) |
| `POST /api/pin` | id |
| `GET /api/commands` | the slash commands, for suggestions |

A message has `id, room, parent, uid, name, avatar, badge, at, edited,
deleted, pinned, replies, last_reply, rev, mentions_me, ignored, body,
html, reactions, files`, and `preview` when the first web link in it has
been looked at: `url, title, description, image, site` (the last three may
be empty). The server fetches the page after the message is posted or
edited and then gives the message a new `rev`, so it comes through the
usual refresh a moment later; a page is kept by address for a week. Show
it folded to one line and load the picture only when a reader opens it.
The admin setting `link_previews` turns the fetching off. `html` is made on the server with members' own
HTML escaped; `body` is what they typed (Markdown).

Slash commands are posted like messages: `/join`, `/part`, `/away`,
`/back`, `/whois`, `/names`, `/invite`, `/kick`, `/op`, `/deop`, `/mute`,
`/unmute`, `/ban`, `/unban`, `/ignore`, `/unignore`, `/topic`, `/me`,
`/help`, plus any that units added on top register. `/msg` is the
client's job: it picks plain or locked for the conversation.

## Files

`POST /api/upload` (multipart: file, expire = hour, day, week, once or
empty, sealed = 1 for an encrypted private file, avatar = 1). Answers a
token to send in `files` with the message. Files download from
`/f/<token>/<name>`.

## Private messages

Encrypted on the device. Each member has an ECDH P-256 key pair; the
public half is on the server (`GET /api/key?name=`), the private half
only wrapped. The key between two members is HKDF-SHA256 over their ECDH
secret (salt 32 zero bytes, info `beginend private message`), used with
AES-GCM; the additional data is `from>to`, both stable key names in lowercase.
Use `key_name` from `/api/me` and `/api/key?name=` for those identities, and
`from_key_name` from each message when opening it. These names stay fixed
when an account is renamed, so old locked messages remain readable. On a
server without these fields, use the displayed names.

| Request | Notes |
|---|---|
| `GET /api/dm?with=&after=&before=` | the newest 100 at first, then newer than `after` or older than `before` |
| `POST /api/dm` | to, iv, data, files (sealed uploads) |
| `POST /api/dm/delete` | `with`: this member's copy of the whole conversation goes, the other keeps theirs. `id`: one message this member sent goes from both sides, with its files; both members get the ring `{"t":"dm","from":name,"deleted":id}`. |
| `POST /api/dm/edit` | id, data, and iv when the conversation is locked: one of the member's own messages, written again; both members get the ring `{"t":"dm","from":name,"edited":id}` |
| `POST /api/dm/react` | id, r (a number from 0, as for `/api/react`): puts the member's reaction on the message, or takes it off; either side may, locked or not; both get the `edited` ring |
| `GET /api/dm/search?with=&q=` | the unlocked messages of the conversation that hold the words, the newest 100; locked messages are never searched |
| `POST /api/beam`, `GET /api/beam`, `POST /api/beam/answer`, `GET /api/ice` | a file sent browser to browser over WebRTC |

Each message of `GET /api/dm` carries `reactions` (a list of `r`, `n` and
`mine`, as on a channel message). An unlocked message (`iv` empty) also
carries `html`, its `text` shaped by the server exactly as a channel
message is (Markdown, colored code, names and channels linked), and
`preview` when its first link has one. A locked message has neither: the
server cannot read it, so a client shapes its text itself.

A message's JSON (`data`, sealed or not) may hold `re`, the message it
answers: `id`, `from` and `text` (its first 140 characters). The sender
wrote it, so show it as text and trust none of it.

## Members

`GET /api/users?q=` (names starting with q), `GET /api/user?name=`,
`POST /api/profile` (bio, links), `POST /api/ignore` (name, on).

## The desktop client

`GET /connect.exedra` answers a small text file (`[exedra]` with
`server=` and `name=`, and a client may add `channel=`) that the desktop
client opens: it adds the server to its list and signs in there.  Pass the
file on, or link to it.

## Running the site

`GET /api/admin` and the `POST /api/admin/...` requests behind the admin
page: settings, member, permission, role, channel. Each needs its own
permission; `GET /api/me` says which the member has.

Safety settings show their stored names on the admin page. The defaults
are `missing_tries=6` per minute (scanner paths count three),
`admin_probe_tries=3` per minute and `password_tries=10` in 15 minutes,
including invalid tokens. Refused admin routes and unknown admin paths
both answer `404 Nothing here.`. `block_strikes=3` makes the third block
permanent; `block_cache_max=10000` drops the oldest cached addresses
(hard cap 100,000). Local and `allowed_ips` addresses retain their block
exemption. IPv6 spellings and mapped IPv4 addresses share counters.

`signuptry_address=10` caps signup attempts per minute across web, IRC and
external sign-in; `signups_per_address=10` caps completed accounts per day.
`signin_tries=10` caps web and IRC password checks together per minute.
`token_tries=30` caps token-link attempts per minute. `tokens_address=30`
and `tokens_member=10` cap token changes per minute. Server mode also has
`live_tries=30` live connection attempts per address per minute.

Transport defaults are `request_body_kb=64`, `request_headers=64`, an 8 KB
header line and `request_read_ms=30000` per socket read (at most 60,000).
Restart after changing transport limits. Uploads and artwork use
`upload_max_mb=5`, plus 64 KB of form overhead, within a 32 MB transport
cap. Layers register larger forms and address/member limits with ChatGuard.
Oversized bodies answer 413; unsupported methods answer 405.
`search_query_bytes=100` caps registered searches, which need two characters.
CGI checks announced sizes before reading; its host controls read deadlines
and the original header count. Rate limits also apply to exempt addresses.

### Private channels and conversations

Both need the permission `manage-private` (admins only, unless a site
grants it). The list says who, when and how much, never what.

`GET /api/admin/private` answers:

```json
{
  "channels": [
    {"slug": "bitbroom", "title": "bitbroom", "owner": "name",
     "members": ["name", "name"], "messages": 12, "archived": false,
     "created": "2026-10-27T12:00:00Z", "last": "2026-11-01T09:30:00Z"}
  ],
  "conversations": [
    {"a": "name", "b": "name", "messages": 40, "locked": true,
     "last": "2026-11-02T21:15:00Z"}
  ]
}
```

`owner` may be empty and `last` may be null or empty for a channel nobody
has spoken in. A conversation both members have deleted is not listed. The
newest thousand conversations are listed.

`POST /api/admin/private/delete` deletes for good and answers a line to
show the person:

| Fields | What goes |
|---|---|
| `kind=channel`, `slug` | the private channel with its messages, threads, files and members. A public channel is refused. |
| `kind=conversation`, `a`, `b` | every message and file between the two, on both sides. A locked conversation stays locked if they talk again. |

After a channel is deleted its members get the ring `{"t": "gone", "room":
slug}`, and `GET /api/room` for it answers 404. After a
conversation is deleted both members get the ring `{"t": "dm", "from": name,
"gone": true}`.
