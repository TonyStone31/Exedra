// The chat: rooms, threads, private conversations and beams, on the
// site's page (app.js), which it adds itself to.  A live connection
// (/api/live) rings when something changes, and the page then asks for it
// (/api/sync); without one, the page asks every few seconds.
(function () {
  'use strict';

  const C = window.Chat;
  const $ = C.$, body = C.body, stream = C.stream, panel = C.panel, Site = C.Site, Me = C.me, S = C.state,
    Extras = C.extras, Reactions = C.Reactions, el = C.el, link = C.link, icon = C.icon,
    iconButton = C.iconButton, get = C.get, post = C.post, enc = C.enc, toast = C.toast,
    failed = C.failed, route = C.route, openPanel = C.openPanel, ago = C.ago, clock = C.clock,
    dayLabel = C.dayLabel, avatar = C.avatar, sizeText = C.sizeText,
    keepPinned = C.keepPinned, nearBottom = C.nearBottom, may = C.may, mayHere = C.mayHere,
    notify = C.notify, popMenu = C.popMenu, joinForm = C.joinForm, layerOpened = C.layerOpened,
    layerClosed = C.layerClosed, toggleMenu = C.toggleMenu;

  // ---------------------------------------------------------------- sidebar

  const Groups = [
    {title: 'Channels', test: function (r) { return r.kind === 'channel'; }, sigil: '#'},
    {title: 'Shelves', test: function (r) { return r.kind === 'shelf'; }, sigil: '~'}
  ];

  function renderSidebar() {
    const nav = $('#roomlist');
    const words = $('#jump').value.toLowerCase().trim();
    nav.replaceChildren();
    let unread = 0;
    for (const g of [Groups[0]].concat(Extras.groups, Groups.slice(1))) {
      const rooms = S.rooms.filter(g.test).filter(function (r) {
        return !words || r.title.toLowerCase().includes(words) || r.slug.includes(words);
      });
      const head = el('div', 'group');
      head.appendChild(el('span', '', g.title === 'Channels' ? t('Channels') : g.title === 'Shelves' ? t('Shelves') : g.title));
      if (g.title === 'Channels' && (may('create-private') || may('create-channel'))) {
        const add = iconButton('plus', t('Open a channel'));
        add.classList.add('small');
        add.addEventListener('click', newRoom);
        head.appendChild(add);
      }
      if (g.button) {
        const extra = el('button', 'small-link', g.button.label);
        extra.type = 'button';
        extra.addEventListener('click', g.button.click);
        head.appendChild(extra);
      }
      if (!rooms.length && !g.always) continue;
      nav.appendChild(head);
      for (const r of rooms) {
        const href = r.kind === 'shelf' ? '/u/' + enc(r.title) : '/p/' + enc(r.slug);
        const a = link(href, 'room');
        a.dataset.slug = r.slug;
        if (r.slug === S.room) a.classList.add('active');
        // a silenced channel keeps quiet: no unread mark and no badge; one on
        // mentions only shows the mention badge alone
        const quiet = r.notify === 'none';
        if (quiet) a.classList.add('quiet');
        if (r.unread && !quiet && r.notify !== 'mentions') a.classList.add('unread');
        if (r.private) {
          const lock = el('span', 'sigil');
          lock.appendChild(icon('lock'));
          a.appendChild(lock);
        } else if (r.avatar) a.appendChild(avatar(r.title, r.avatar, 'tiny roomicon'));
        else a.appendChild(el('span', 'sigil', g.sigil));
        a.appendChild(el('span', 'name', r.title));
        if (r.mentions && !quiet) a.appendChild(el('span', 'badge mention', '@' + r.mentions));
        else if (r.unread && !quiet && r.notify !== 'mentions') a.appendChild(el('span', 'badge', r.unread > 99 ? '99+' : String(r.unread)));
        // The row's own menu: how much it may bother you, leave, and for a
        // private channel of one's own, delete.
        const items = roomMenuItems(r);
        if (items.length) {
          const more = iconButton('down', t('More'), 'rowmenu');
          more.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopPropagation();
            popMenu(more, items);
          });
          a.appendChild(more);
        }
        nav.appendChild(a);
        if (!quiet) unread += r.mentions;
      }
    }
    if (S.dms.length) {
      const head = el('div', 'group');
      head.appendChild(el('span', '', t('Private')));
      nav.appendChild(head);
      for (const d of S.dms) {
        if (words && !d.name.toLowerCase().includes(words)) continue;
        const a = link('/dm/' + enc(d.name), 'room person');
        if (S.view === 'dm' && S.dm === d.name) a.classList.add('active');
        if (d.unread) a.classList.add('unread');
        a.append(avatar(d.name, d.avatar, 'tiny'), el('span', 'name', d.name));
        if (d.unread) a.appendChild(el('span', 'badge mention', String(d.unread)));
        const more = iconButton('down', t('More'), 'rowmenu');
        more.addEventListener('click', function (e) {
          e.preventDefault();
          e.stopPropagation();
          popMenu(more, [[t('Delete conversation'), function () { deleteDm(d.name); }]]);
        });
        a.appendChild(more);
        nav.appendChild(a);
        unread += d.unread;
      }
    }
    document.title = (unread ? '(' + unread + ') ' : '') + (S.title || Site) + ' - ' + Site;
  }

  function roomMenuItems(r) {
    const items = [];
    if (!Me.name || r.kind === 'shelf') return items;
    if (r.notify !== 'none') items.push([t('Silence channel'), function () { setNotify(r, 'none'); }]);
    if (r.notify !== 'mentions') items.push([t('Mentions only'), function () { setNotify(r, 'mentions'); }]);
    if (r.notify && r.notify !== 'all') items.push([t('Notify about everything'), function () { setNotify(r, 'all'); }]);
    items.push([t('Leave channel'), function () { leaveRoom(r); }]);
    if (r.private && r.owner) items.push([t('Delete channel'), function () { deleteRoom(r); }]);
    return items;
  }

  // How much the channel may bother this member: all, mentions or none.  The
  // server stops pushing and mailing about a silenced one; the page stops
  // badging and announcing it.
  async function setNotify(r, mode) {
    try {
      await post('/api/follow/notify', {room: r.slug, mode: mode});
      r.notify = mode;
      renderSidebar();
      toast(mode === 'none' ? t('%s is silenced.', r.title) : mode === 'mentions' ? t('Only mentions in %s from now on.', r.title) :
        t('%s notifies about everything again.', r.title));
    } catch (err) { failed(err); }
  }

  // Leaving takes the channel out of the sidebar; a private one asks first,
  // since only an invite gets the member back in.
  async function leaveRoom(r) {
    if (r.private && !confirm(t('Leave %s? Only an invite gets you back in.', r.title))) return;
    try {
      await post('/api/follow', {room: r.slug, on: '0'});
      S.rooms = S.rooms.filter(function (x) { return x.slug !== r.slug; });
      renderSidebar();
      if (S.view === 'room' && S.room === r.slug) route('/', true);
      else syncNow(true);
    } catch (err) { failed(err); }
  }

  // The owner's private channel, gone for good with everything in it; the
  // other members' pages leave it on the server's ring.
  async function deleteRoom(r) {
    if (!confirm(t('Delete %s?\n\nEverything said in it and every file goes, for everyone in it. This cannot be undone.', r.title))) return;
    try {
      const said = await post('/api/room/delete', {slug: r.slug});
      S.rooms = S.rooms.filter(function (x) { return x.slug !== r.slug; });
      renderSidebar();
      if (S.view === 'room' && S.room === r.slug) route('/', true);
      toast(typeof said === 'string' ? said : t('Channel deleted.'));
    } catch (err) { failed(err); }
  }

  // This member's copy only; the other keeps theirs (/api/dm/delete).
  async function deleteDm(name) {
    if (!confirm(t('Delete your conversation with %s?\n\nYour copy is gone for good. %s keeps theirs. If they write again, a new conversation starts.', name, name))) return;
    try {
      await post('/api/dm/delete', {with: name});
      S.dms = S.dms.filter(function (d) { return d.name !== name; });
      renderSidebar();
      if (S.view === 'dm' && S.dm === name) route('/', true);
      toast(t('Conversation deleted.'));
    } catch (err) { failed(err); }
  }

  $('#jump').addEventListener('input', renderSidebar);
  $('#jump').addEventListener('keydown', function (e) {
    if (e.key !== 'Enter') return;
    const first = $('#roomlist a.room');
    if (first) { route(first.getAttribute('href'), true); this.value = ''; renderSidebar(); }
  });

  // Mentions and private messages that arrive while the member looks
  // elsewhere become a notification.
  function notifyNews(rooms, dms) {
    const seen = S.alerts;
    const news = [];
    for (const r of rooms) {
      const key = 'r:' + r.slug;
      if (seen[key] !== undefined && r.mentions > seen[key] && r.notify !== 'none' && (document.hidden || r.slug !== S.room))
        news.push(t('You were mentioned in %s', (r.kind === 'channel' ? '#' : '') + r.title));
      seen[key] = r.mentions;
    }
    for (const d of dms) {
      const key = 'd:' + d.name;
      if (seen[key] !== undefined && d.unread > seen[key] && (document.hidden || S.dm !== d.name))
        news.push(t('%s sent you a private message', d.name));
      seen[key] = d.unread;
    }
    if (!news.length) return;
    if ('Notification' in window && Notification.permission === 'granted' && document.hidden)
      notify(Site, news.join('\n'));
    else
      news.forEach(function (n) { toast(n); });
  }

  // Holding a message on a touch screen shows our buttons, with the quick
  // reactions open, and not the browser's menu; links, pictures and code
  // keep the browser's.  The text is not selectable by touch (site.css), or
  // the phone would start selecting it instead: Copy is one of our buttons.
  let lastPointer = '';
  document.addEventListener('pointerdown', function (e) {
    lastPointer = e.pointerType;
    const held = $('.msg.held');
    if (held && !held.contains(e.target)) held.classList.remove('held');
  });
  document.addEventListener('contextmenu', function (e) {
    const msg = e.target.closest('.msg');
    if (lastPointer !== 'touch' || !msg || e.target.closest('a, img, pre, code, .actions')) return;
    e.preventDefault();
    msg.classList.add('held');
    const react = msg.querySelector('.reactbtn');
    if (react) react.click();
  });

  // ------------------------------------------------------------------ rooms

  function roomTitle(info) {
    if (info.kind === 'channel') return '#' + info.title;
    return info.title;
  }

  function renderHead(info, extra) {
    const head = $('#roomhead');
    head.replaceChildren();
    const menu = iconButton('menu', t('Channels'), 'menubtn');
    menu.addEventListener('click', toggleMenu);
    head.appendChild(menu);
    const titles = el('div', 'titles');
    const h = el('h1');
    h.appendChild(el('span', 'roomname', roomTitle(info)));
    if (info.avatar) h.prepend(avatar(info.title, info.avatar, 'small roomicon'));
    if (info.private) {
      h.prepend(icon('lock'));
      h.appendChild(el('span', 'kindtag', t('private')));
    } else if (info.kind !== 'channel') h.appendChild(el('span', 'kindtag', info.kind));
    titles.appendChild(h);
    const topic = el('p', 'topic', info.topic || '');
    if (info.can && info.can['set-topic']) {
      topic.title = t('Click to change the topic');
      topic.classList.add('editable');
      if (!info.topic) topic.textContent = t('Add a topic');
      topic.addEventListener('click', async function () {
        const next = prompt(t('Topic for %s', roomTitle(info)), info.topic || '');
        if (next === null) return;
        try {
          await post('/api/topic', {room: info.slug, topic: next});
          info.topic = next;
          topic.textContent = next || t('Add a topic');
        } catch (err) { failed(err); }
      });
    }
    titles.appendChild(topic);
    head.appendChild(titles);
    const here = el('button', 'here');
    here.type = 'button';
    here.title = t('Who is here');
    here.addEventListener('click', openMembers);
    head.appendChild(here);
    const tools = el('div', 'headtools');
    if (extra) tools.appendChild(extra);
    if (Me.name && info.kind !== 'shelf') {
      const follow = el('button', 'pill ' + (info.following ? 'on' : ''), info.following ? t('Following') : t('Follow'));
      follow.type = 'button';
      follow.title = info.private ? t('If you leave a private channel, someone must invite you back') :
        t('Followed channels sit in your sidebar with their unread counts');
      follow.addEventListener('click', async function () {
        if (info.private && info.following && !confirm(t('Leave %s? Only an invite gets you back in.', info.title))) return;
        try {
          await post('/api/follow', {room: info.slug, on: info.following ? '0' : '1'});
          info.following = !info.following;
          follow.textContent = info.following ? t('Following') : t('Follow');
          follow.classList.toggle('on', info.following);
          syncNow(true);
        } catch (err) { failed(err); }
      });
      // Beside the name: it is about this room.
      h.appendChild(follow);
    }
    const people = iconButton('people', t('People: who is here, and who is in this channel or runs it'));
    people.addEventListener('click', openMembers);
    tools.appendChild(people);
    const pins = iconButton('pin', t('Pinned messages'));
    pins.addEventListener('click', openPins);
    const search = iconButton('search', t('Search'));
    search.addEventListener('click', openSearch);
    tools.append(pins, search);
    head.appendChild(tools);
  }

  function renderHere(list) {
    const box = $('#roomhead .here');
    if (!box) return;
    box.replaceChildren();
    S.here = list;
    for (const p of list.slice(0, 6)) {
      const a = avatar(p.name, p.avatar, 'tiny' + (p.away ? ' away' : ''));
      a.title = p.away ? t('%s is away: %s', p.name, p.away) : t('%s is here', p.name);
      box.appendChild(a);
    }
    if (list.length) box.appendChild(el('span', 'count', tn(list.length, '%d here', '%d here')));
  }

  // Who is typing: from the live connection's rings and from each sync,
  // each name shown for five seconds after it was last heard.
  function noteTyping(names) {
    for (const n of names) if (n !== Me.name) S.typers[n] = Date.now() + 5000;
    renderTyping();
  }

  setInterval(function () { if (Object.keys(S.typers).length) renderTyping(); }, 1000);

  function renderTyping() {
    const box = $('#typing');
    const now = Date.now();
    for (const n of Object.keys(S.typers)) if (S.typers[n] < now) delete S.typers[n];
    const names = Object.keys(S.typers);
    if (!names.length) { box.replaceChildren(); return; }
    let text = names.length === 1 ? t('%s is typing', names[0]) :
      names.length === 2 ? t('%s and %s are typing', names[0], names[1]) : t('Several people are typing');
    box.replaceChildren(el('span', 'dots'), el('span', '', text));
  }

  async function openRoom(slug, thread) {
    const generation = S.generation;
    const info = await get('/api/room?slug=' + enc(slug));
    if (generation !== S.generation) return;
    S.view = 'room';
    S.room = info.slug;
    S.info = info;
    S.title = roomTitle(info);
    // the room last used, for the pages around the chat to open their bubble on
    if (!info.private) try { localStorage.setItem('last-room', info.slug); } catch (e) { }
    renderHead(info);
    renderCard(info);
    await loadMessages(generation);
    renderComposer($('#composer-area'), 0);
    if (thread) openThread(thread);
    syncNow(true);
  }

  async function loadMessages(generation) {
    const data = await get('/api/messages?room=' + enc(S.room));
    if (generation !== S.generation) return;
    S.lastRead = data.last_read;
    S.divider = 0;
    S.since = data.rev - 3000000;
    S.oldest = Infinity;
    S.older = data.messages.length === 50;
    for (const m of data.messages) {
      if (!S.divider && Me.name && m.id > S.lastRead && m.name !== Me.name && S.lastRead > 0) S.divider = m.id;
    }
    addMessages(data.messages, true);
    if (!data.messages.length) stream.appendChild(emptyNote());
  }

  function emptyNote() {
    const p = el('div', 'empty');
    p.appendChild(el('b', '', t('Nothing said here yet.')));
    p.appendChild(el('span', '', Me.name ? t(' Say hello.') : t(' Join to say hello.')));
    return p;
  }

  stream.addEventListener('scroll', async function () {
    if (stream.scrollTop <= 80 && S.view === 'dm') { olderDms(); return; }
    if (stream.scrollTop > 80 || !S.older || S.view !== 'room' || S.loadingOlder) return;
    S.loadingOlder = true;
    const generation = S.generation;
    try {
      const data = await get('/api/messages?room=' + enc(S.room) + '&before=' + S.oldest);
      if (generation !== S.generation) return;
      const height = stream.scrollHeight;
      S.older = data.messages.length === 50;
      for (const m of data.messages) upsert(m, stream, S.messages, false);
      regroup(stream);
      stream.scrollTop = stream.scrollHeight - height;
    } catch (err) { failed(err); }
    // finally: a room changed meanwhile must not leave the older pages shut
    finally { S.loadingOlder = false; }
  });

  function addMessages(list, initial) {
    const stick = initial || stream.pinned || nearBottom();
    const empty = $('.empty', stream);
    if (empty && list.length) empty.remove();
    for (const m of list) upsert(m, stream, S.messages, false);
    regroup(stream);
    if (stick) { stream.scrollTop = stream.scrollHeight; stream.pinned = true; }
  }

  function upsert(m, box, map, inThread) {
    const old = map.get(m.id);
    if (old && old.data.rev === m.rev) return;
    const node = renderMessage(m, inThread);
    if (old) old.node.replaceWith(node);
    else {
      let after = null;
      const nodes = box.querySelectorAll(':scope > .msg');
      for (let i = nodes.length - 1; i >= 0; i--) {
        if (Number(nodes[i].dataset.id) < m.id) { after = nodes[i]; break; }
      }
      if (after) after.after(node);
      else box.prepend(node);
    }
    map.set(m.id, {data: m, node: node});
    if (box === stream && m.id < S.oldest) S.oldest = m.id;
  }

  // Runs of messages by one person close together share one header; days
  // and the first unread message get a line.
  function regroup(box) {
    box.querySelectorAll(':scope > .day, :scope > .divider').forEach(function (d) { d.remove(); });
    let prev = null;
    for (const node of box.querySelectorAll(':scope > .msg')) {
      const when = new Date(node.dataset.at);
      const day = when.toDateString();
      if (!prev || new Date(prev.dataset.at).toDateString() !== day) {
        const line = el('div', 'day');
        line.appendChild(el('span', '', dayLabel(when)));
        node.before(line);
        prev = null;
      }
      if (box === stream && S.divider && Number(node.dataset.id) === S.divider) {
        const line = el('div', 'divider');
        line.appendChild(el('span', '', t('New')));
        node.before(line);
        prev = null;
      }
      const together = prev && prev.dataset.name === node.dataset.name && !prev.classList.contains('system')
        && when - new Date(prev.dataset.at) < 6 * 60000 && !node.classList.contains('hasthread')
        && !prev.classList.contains('hasthread');
      node.classList.toggle('cont', !!together);
      prev = node;
    }
  }

  // --------------------------------------------------------------- messages

  function renderMessage(m, inThread) {
    const node = el('article', 'msg');
    node.dataset.id = m.id;
    node.dataset.at = m.at;
    node.dataset.name = m.name;
    if (!m.uid) node.classList.add('system');
    if (m.name === Me.name) node.classList.add('mine');
    if (m.mentions_me) node.classList.add('mention');
    if (m.deleted) node.classList.add('deleted');
    if (m.replies && !inThread) node.classList.add('hasthread');

    const gutter = el('div', 'gutter');
    if (m.uid) {
      const a = link('/u/' + enc(m.name), 'face');
      a.appendChild(avatar(m.name, m.avatar));
      gutter.appendChild(a);
    } else gutter.appendChild(avatar(m.name, '', 'bot'));
    const at = new Date(m.at);
    gutter.appendChild(el('time', 'side-time', clock(at)));
    node.appendChild(gutter);

    const content = el('div', 'content');
    const head = el('header');
    if (m.uid) head.appendChild(link('/u/' + enc(m.name), 'who', m.name));
    else head.appendChild(el('b', 'who', m.name));
    if (m.badge) head.appendChild(el('span', 'role', m.badge));
    for (const badge of Extras.badges) {
      const b = badge(m);
      if (b) head.appendChild(b);
    }
    if (m.room !== S.room && !inThread) head.appendChild(link('/p/' + enc(m.room), 'where', '#' + m.room));
    const time = el('time', '', clock(at));
    time.title = dateTimeText(at);
    head.appendChild(time);
    if (m.edited && !m.deleted) head.appendChild(el('span', 'edited', t('(edited)')));
    if (m.pinned) head.appendChild(el('span', 'pinned', t('pinned')));
    content.appendChild(head);

    const text = el('div', 'body');
    if (m.deleted) text.textContent = t('This message was deleted.');
    else { text.innerHTML = m.html; dressCode(text); }   // safe html: rendered by the server, members' HTML escaped
    content.appendChild(text);
    if (m.preview && !m.deleted) content.appendChild(previewOf(m.preview));
    // Someone the member ignores: folded, one click to read anyway.
    if (m.ignored && !m.deleted) {
      node.classList.add('ignored');
      const show = el('button', 'unfold', t('A message from %s, whom you ignore. Show it', m.name));
      show.type = 'button';
      show.addEventListener('click', function () { node.classList.remove('ignored'); show.remove(); });
      content.insertBefore(show, text);
    }
    if (m.files && m.files.length) content.appendChild(renderFiles(m.files));
    if (m.reactions && m.reactions.length) content.appendChild(renderReactions(m));
    if (m.replies && !inThread) {
      const t = el('button', 'threadline');
      t.type = 'button';
      t.appendChild(icon('reply'));
      t.appendChild(el('b', '', tn(m.replies, '%d reply', '%d replies')));
      t.appendChild(el('span', '', window.t('last %s', ago(m.last_reply))));
      t.addEventListener('click', function () { openThread(m.id); });
      content.appendChild(t);
    }
    node.appendChild(content);
    if (!m.deleted) node.appendChild(renderActions(m, inThread));
    return node;
  }

  function renderFiles(files) {
    const box = el('div', 'files');
    for (const f of files) {
      if (f.image) {
        const a = link(f.url, 'shot');
        const img = el('img');
        img.src = f.url;
        img.alt = f.name;
        img.loading = 'lazy';
        // A picture that arrives after the scroll keeps the stream at the bottom.
        img.addEventListener('load', function () {
          const list = img.closest('#stream, .threadlist');
          if (list && (list.pinned || list.scrollHeight - list.scrollTop - list.clientHeight < img.height + 200))
            list.scrollTop = list.scrollHeight;
        });
        a.appendChild(img);
        box.appendChild(a);
      } else {
        const a = link(f.url, 'file');
        a.appendChild(icon('attach'));
        a.appendChild(el('span', 'fname', f.name));
        a.appendChild(el('span', 'fsize', sizeText(f.size)));
        if (f.once) a.appendChild(el('span', 'fexp', t('deletes after one download')));
        else if (f.expires) a.appendChild(el('span', 'fexp', t('until %s', dateTimeText(f.expires))));
        box.appendChild(a);
      }
    }
    return box;
  }

  function renderReactions(m) {
    const box = el('div', 'reacts');
    for (const r of m.reactions) {
      const b = el('button', 'react' + (r.mine ? ' mine' : ''), Reactions[r.r] + ' ' + r.n);
      b.type = 'button';
      b.addEventListener('click', function () { react(m.id, r.r, m.dm); });
      box.appendChild(b);
    }
    return box;
  }

  // dm: the message is a private one, which has its own numbers and its own place
  async function react(id, r, dm) {
    if (!Me.name) return toast(t('Join to react.'));
    try {
      if (dm) { await post('/api/dm/react', {id: id, r: r}); refreshDm(id); return; }
      await post('/api/react', {id: id, r: r});
      syncNow();
    } catch (err) { failed(err); }
  }

  // What the first link in a message leads to, folded to one line: the
  // site and the title.  A click opens the description and the picture;
  // the picture is asked for only then, so reading the room tells the
  // other site nothing.
  function previewOf(p) {
    const box = el('div', 'preview');
    const line = el('button', 'line');
    line.type = 'button';
    let host = p.site;
    if (!host) { try { host = new URL(p.url).host; } catch (e) { host = ''; } }
    line.append(el('span', 'site', host), el('span', 'title', p.title || p.url));
    line.title = p.url;
    const more = el('div', 'more');
    more.hidden = true;
    if (p.description) more.appendChild(el('p', '', p.description));
    const go = el('a', 'small-link', t('Open the page'));
    go.href = p.url;
    go.target = '_blank';
    go.rel = 'noopener nofollow ugc';
    more.appendChild(go);
    line.addEventListener('click', function () {
      const open = box.classList.toggle('open');
      more.hidden = !open;
      if (open && p.image && !more.querySelector('img')) {
        const img = el('img');
        img.alt = '';
        img.referrerPolicy = 'no-referrer';
        img.src = p.image;
        more.prepend(img);
      }
    });
    box.append(line, more);
    return box;
  }

  function renderActions(m, inThread) {
    const bar = el('div', 'actions');
    if (Me.name && mayHere('react')) {
      const r = iconButton('react', t('React'), 'reactbtn');
      r.addEventListener('click', function () { picker(r, m.id); });
      bar.appendChild(r);
      if (!inThread && !m.parent) {
        const t = iconButton('reply', window.t('Reply in a thread'));
        t.addEventListener('click', function () { openThread(m.id); });
        bar.appendChild(t);
      }
    }
    if (m.body) {
      const c = iconButton('copy', t('Copy the text'));
      c.addEventListener('click', function () {
        navigator.clipboard.writeText(m.body).then(function () { toast(t('Text copied.')); });
      });
      bar.appendChild(c);
    }
    const l = iconButton('link', t('Copy a link to this'));
    l.addEventListener('click', function () {
      navigator.clipboard.writeText(location.origin + '/m/' + m.id).then(function () { toast(t('Link copied.')); });
    });
    bar.appendChild(l);
    if (m.name === Me.name && m.uid && may('edit-own')) {
      const e = iconButton('edit', t('Edit'));
      e.addEventListener('click', function () { startEdit(m); });
      bar.appendChild(e);
    }
    if ((m.name === Me.name && m.uid && may('delete-own')) || mayHere('delete-any')) {
      const d = iconButton('trash', t('Delete'));
      d.addEventListener('click', async function () {
        if (!confirm(t('Delete this message?'))) return;
        try { await post('/api/delete', {id: m.id}); syncNow(); } catch (err) { failed(err); }
      });
      bar.appendChild(d);
    }
    if (mayHere('pin') && !m.parent) {
      const p = iconButton('pin', m.pinned ? t('Unpin') : t('Pin to the channel'));
      p.addEventListener('click', async function () {
        try { await post('/api/pin', {id: m.id}); syncNow(); } catch (err) { failed(err); }
      });
      bar.appendChild(p);
    }
    return bar;
  }

  function picker(anchor, id, dm) {
    document.querySelectorAll('.picker').forEach(function (p) { p.remove(); });
    const box = el('div', 'picker');
    Reactions.forEach(function (r, i) {
      const b = el('button', '', r);
      b.type = 'button';
      b.addEventListener('click', function () { box.remove(); react(id, i, dm); });
      box.appendChild(b);
    });
    anchor.closest('.actions').appendChild(box);
    // the last messages have no room below: the composer would cover it
    const list = anchor.closest('#stream, .threadlist');
    if (list) {
      const room = list.getBoundingClientRect();
      const r = box.getBoundingClientRect();
      if (r.bottom > room.bottom - 8 && r.top - room.top > room.bottom - r.top) box.classList.add('up');
    }
    setTimeout(function () {
      document.addEventListener('click', function close(e) {
        if (!box.contains(e.target)) { box.remove(); document.removeEventListener('click', close); }
      });
    });
  }

  function startEdit(m) {
    const entry = S.messages.get(m.id) || S.threadMessages.get(m.id);
    if (!entry) return;
    const text = entry.node.querySelector('.body');
    const box = el('div', 'editbox');
    const area = el('textarea');
    area.value = m.body;
    const save = el('button', 'primary', t('Save'));
    const cancel = el('button', '', t('Cancel'));
    save.type = cancel.type = 'button';
    box.append(area, save, cancel);
    text.replaceWith(box);
    area.focus();
    fit(area);
    const done = function () { box.replaceWith(text); };
    const store = async function () {
      try { await post('/api/edit', {id: m.id, body: area.value}); done(); syncNow(); } catch (err) { failed(err); }
    };
    save.addEventListener('click', store);
    cancel.addEventListener('click', done);
    area.addEventListener('input', function () { fit(area); });
    area.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') done();
      if (e.key === 'Enter' && !e.shiftKey && !inFence(area)) { e.preventDefault(); store(); }
    });
  }

  // A code block as it is shown: its language by its proper name, how many
  // lines it has, a number beside each line, and a long one folded to its
  // first lines until asked for.  Copy always takes all of it, numbers left out.
  const CODE_NAMES = {pascal: 'Pascal', lfm: 'LFM', bash: 'Bash', javascript: 'JavaScript', js: 'JavaScript', typescript: 'TypeScript', ts: 'TypeScript',
    css: 'CSS', html: 'HTML', xml: 'XML', sql: 'SQL', json: 'JSON', ini: 'INI', yaml: 'YAML', toml: 'TOML', go: 'Go', c: 'C', cpp: 'C++',
    csharp: 'C#', java: 'Java', kotlin: 'Kotlin', swift: 'Swift', rust: 'Rust', zig: 'Zig', d: 'D', python: 'Python', ruby: 'Ruby', lua: 'Lua',
    php: 'PHP', perl: 'Perl', basic: 'BASIC', diff: 'Diff', makefile: 'Makefile', asm: 'Assembly', batch: 'Batch', powershell: 'PowerShell',
    dockerfile: 'Dockerfile', fortran: 'Fortran', ada: 'Ada', barye: 'Barye', markdown: 'Markdown', md: 'Markdown', rst: 'reStructuredText', restructuredtext: 'reStructuredText'};
  const FOLD_LINES = 20;
  function dressCode(root) {
    for (const box of root.querySelectorAll('.code')) {
      const pre = box.querySelector(':scope > pre'), code = pre && pre.querySelector(':scope > code');
      if (!code || pre.querySelector('.nums')) continue;
      const lines = code.textContent.replace(/\n+$/, '').split('\n').length;
      const label = box.querySelector(':scope > .codebar span');
      if (label) {
        const id = label.textContent.trim().toLowerCase();
        label.textContent = CODE_NAMES[id] || label.textContent.trim();
        if (lines > 1) label.after(el('span', 'codelines', tn(lines, '%d line', '%d lines')));
      }
      // a markdown block shows as its document; the button flips to its source
      const flip = box.querySelector(':scope > .codebar .flip');
      if (flip) { flip.textContent = t('Source'); flip.setAttribute('aria-pressed', 'false'); }
      if (lines < 2) continue;
      const nums = el('span', 'nums');
      nums.setAttribute('aria-hidden', 'true');
      let list = '';
      for (let i = 1; i <= lines; i++) list += i + '\n';
      nums.textContent = list;
      pre.prepend(nums);
      box.classList.add('numbered');
      // a few lines past the fold are not worth a button
      if (lines <= FOLD_LINES + 5) continue;
      box.classList.add('folded');
      const fold = el('button', 'codefold');
      fold.type = 'button';
      const say = function () {
        const shut = box.classList.contains('folded');
        fold.textContent = shut ? tn(lines, 'Show all %d line', 'Show all %d lines') : t('Show less');
        fold.setAttribute('aria-expanded', shut ? 'false' : 'true');
      };
      fold.addEventListener('click', function () {
        box.classList.toggle('folded');
        say();
        if (box.classList.contains('folded') && box.getBoundingClientRect().top < 0) box.scrollIntoView({block: 'nearest'});
      });
      say();
      box.appendChild(fold);
    }
  }

  // Code blocks copy; pictures open large.
  document.addEventListener('click', function (e) {
    const flip = e.target.closest('.code .flip');
    if (flip) {
      const box = flip.closest('.code'), source = box.classList.toggle('source');
      flip.textContent = source ? t('Rendered') : t('Source');
      flip.setAttribute('aria-pressed', source ? 'true' : 'false');
      return;
    }
    const copy = e.target.closest('.code .copy');
    if (copy) {
      navigator.clipboard.writeText(copy.closest('.code').querySelector(':scope > pre > code').textContent).then(function () {
        copy.textContent = t('Copied');
        setTimeout(function () { copy.textContent = t('Copy'); }, 1500);
      });
      return;
    }
    const shot = e.target.closest('a.shot');
    if (shot && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      const box = $('#lightbox');
      const img = el('img');
      img.src = shot.href;
      box.replaceChildren(img);
      box.hidden = false;
      layerOpened();
    }
  });
  $('#lightbox').addEventListener('click', function () { this.hidden = true; layerClosed(); });

  // ------------------------------------------------------------------- sync

  let syncTimer = 0;
  let syncing = false;
  let again = false;
  let roomsWanted = false;
  let sidebarTimer = 0;

  function syncNow(withRooms) {
    if (withRooms) roomsWanted = true;
    clearTimeout(syncTimer);
    sync();
  }

  // The sidebar's counts, asked for a little later, so a busy channel's
  // messages do not each send every follower's page to ask at once.
  function sidebarSoon(ms) {
    if (sidebarTimer) return;
    sidebarTimer = setTimeout(function () { sidebarTimer = 0; syncNow(true); }, ms);
  }

  let fromRing = false;

  async function sync() {
    // One at a time; a ring during a sync makes another right after.
    if (syncing) { again = true; return; }
    syncing = true;
    again = false;
    const generation = S.generation;
    const params = new URLSearchParams({since: S.since});
    // Asked because of a ring: only what changed.  Otherwise also say we
    // are here and hear who else is.
    if (!fromRing) params.set('here', '1');
    fromRing = false;
    if (S.view === 'room') params.set('room', S.room);
    if (S.thread) params.set('thread', S.thread);
    if (Live.id) params.set('live', Live.id);
    if (Me.name && (roomsWanted || (!Live.id && S.tick % 5 === 0))) params.set('rooms', '1');
    roomsWanted = false;
    if (S.view === 'room' && !document.hidden && nearBottom() && S.messages.size)
      params.set('read', Math.max.apply(null, Array.from(S.messages.keys())));
    S.tick++;
    try {
      const a = await get('/api/sync?' + params);
      if (generation === S.generation) {
        if (a.messages) addMessages(a.messages, false);
        if (a.thread) addThread(a.thread);
        if (a.typing) noteTyping(a.typing);
        if (a.here) renderHere(a.here);
        // More than one answer holds: carry on from the last one given.
        if (a.more) {
          S.since = a.messages[a.messages.length - 1].rev;
          again = true;
        } else S.since = Math.max(S.since, a.rev - 3000000);
      }
      if (a.rooms) {
        notifyNews(a.rooms, a.dms || []);
        S.rooms = a.rooms;
        S.dms = a.dms || [];
        renderSidebar();
      }
    } catch (err) {
      // The next one tries again.
    }
    syncing = false;
    clearTimeout(syncTimer);
    if (again) { sync(); return; }
    // With a live connection the rings say when; the timer only keeps
    // presence fresh.  Without one, ask often.
    syncTimer = setTimeout(sync, Live.id ? 50000 : document.hidden ? 15000 : 3000);
  }

  document.addEventListener('visibilitychange', function () { if (!document.hidden) syncNow(true); });

  // ------------------------------------------------------------------- live

  const Live = {ws: null, id: '', wait: 1000, failures: 0};

  function connectLive() {
    if (!('WebSocket' in window) || Live.failures > 4) return;
    let ws;
    try {
      ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/live');
    } catch (err) { return; }
    Live.ws = ws;
    ws.onmessage = function (e) {
      let note;
      try { note = JSON.parse(e.data); } catch (err) { return; }
      heard(note);
    };
    ws.onclose = function () {
      // A server without live connections (a CGI site) fails every time;
      // after a few the page settles for asking on a timer.
      if (!Live.id) Live.failures++;
      Live.id = '';
      Live.ws = null;
      setTimeout(connectLive, Live.wait);
      Live.wait = Math.min(Live.wait * 2, 30000);
    };
  }

  setInterval(function () { if (Live.ws && Live.ws.readyState === 1) Live.ws.send('ping'); }, 25000);
  // A page nobody looks at should not keep pushes from coming.
  document.addEventListener('visibilitychange', function () {
    if (Live.ws && Live.ws.readyState === 1) Live.ws.send(document.hidden ? 'hidden' : 'shown');
  });

  // A new message that came with its ring: shown without asking.  The
  // server sends it as anyone sees it, so this page works out the parts
  // that are about this member.
  let readTimer = 0;
  function arrived(m) {
    const lower = Me.name.toLowerCase();
    m.mentions_me = !!Me.name && (m.names || []).some(function (n) { return n.toLowerCase() === lower; });
    m.ignored = Me.ignores.indexOf(m.uid) >= 0;
    if (m.parent) {
      if (S.thread === m.parent) addThread([m]);
      const p = S.messages.get(m.parent);
      if (p) upsert(Object.assign({}, p.data, {replies: p.data.replies + 1, last_reply: m.at, rev: p.data.rev + 1}),
        stream, S.messages, false);
    } else addMessages([m], false);
    // Tell the server what was read, a little later, once for a burst.
    if (!readTimer && Me.name) readTimer = setTimeout(function () { readTimer = 0; fromRing = true; sync(); }, 4000 + Math.random() * 6000);
  }

  function heard(note) {
    if (note.t === 'names') {
      location.reload();
      return;
    } else if (note.t === 'hello') {
      Live.id = note.id;
      Live.wait = 1000;
      Live.failures = 0;
      syncNow(true);
      leaveIfGone().catch(function () { });
    } else if (note.t === 'room') {
      if (note.room === S.room && note.m) arrived(note.m);
      else if (note.room === S.room) setTimeout(function () { fromRing = true; sync(); }, Math.random() * 300);
      else {
        const r = S.rooms.find(function (x) { return x.slug === note.room; });
        if (r) {
          if (!r.unread) { r.unread = 1; renderSidebar(); }
          sidebarSoon(2000 + Math.random() * 6000);
        }
      }
    } else if (note.t === 'typing') {
      if (note.room === S.room) noteTyping([note.name]);
    } else if (note.t === 'dmtyping') {
      if (S.view === 'dm' && note.from === S.dm) noteTyping([note.from]);
    } else if (note.t === 'me') {
      sidebarSoon(300);
    } else if (note.t === 'gone') {
      if (note.room === S.room) leaveChannel(t('This channel was deleted.'));
      sidebarSoon(300);
    } else if (note.t === 'dm') {
      if (note.gone && S.view === 'dm' && note.from === S.dm) route(location.pathname, false);
      else if (note.deleted && S.view === 'dm' && note.from === S.dm) dropDm(note.deleted);
      else if (note.edited && S.view === 'dm' && note.from === S.dm) refreshDm(note.edited);
      else if (S.view === 'dm' && (note.from === S.dm || note.from === Me.name)) {
        // their message is here: they are no longer typing it
        if (S.typers[note.from]) { delete S.typers[note.from]; renderTyping(); }
        pollNow();
      }
      sidebarSoon(300);
    }
  }

  // A private channel can close under an open page: a kick, or the people
  // running the site deleting it.  Either way the server drops the live
  // connection, so this asks again when it comes back.
  async function leaveIfGone() {
    if (S.view !== 'room' || !S.info || !S.info.private) return;
    const slug = S.room;
    const answer = await fetch('/api/room?slug=' + enc(slug));
    if (answer.status !== 404 || S.view !== 'room' || S.room !== slug) return;
    leaveChannel(t('You are no longer in #%s.', slug));
  }

  let leaving = false;
  function leaveChannel(why) {
    if (leaving) return;
    leaving = true;
    toast(why);
    setTimeout(function () { location.assign('/'); }, 2500);
  }

  async function openThread(id) {
    const box = openPanel(t('Thread'), 'thread');
    S.thread = id;
    S.threadMessages.clear();
    const list = el('div', 'threadlist');
    box.appendChild(list);
    keepPinned(list);
    if (location.pathname !== '/m/' + id) history.replaceState({}, '', '/m/' + id);
    try {
      const messages = await get('/api/thread?id=' + id);
      if (S.thread !== id) return;
      addThread(messages);
    } catch (err) { failed(err); }
    const area = el('div', 'panelcomposer');
    box.appendChild(area);
    renderComposer(area, id);
  }

  function addThread(messages) {
    const list = $('.threadlist', panel);
    if (!list) return;
    const stick = list.pinned || nearBottom(list);
    for (const m of messages) upsert(m, list, S.threadMessages, true);
    const root = list.querySelector('.msg');
    if (root && !$('.threadcount', list)) root.after(el('div', 'threadcount'));
    const count = $('.threadcount', list);
    if (count) count.textContent = tn(S.threadMessages.size - 1, '%d replies', '%d replies');
    regroup(list);
    if (stick) list.scrollTop = list.scrollHeight;
  }

  async function openPins() {
    const box = openPanel(t('Pinned'), 'pins');
    try {
      const list = await get('/api/pins?room=' + enc(S.room));
      if (!list.length) box.appendChild(el('p', 'notice', t('Nothing is pinned here. The channel\'s owner and moderators pin messages that should stay in view.')));
      const holder = el('div', 'threadlist');
      for (const m of list) holder.appendChild(renderMessage(m, true));
      box.appendChild(holder);
    } catch (err) { failed(err); }
  }

  // Who is here now, then who is in a private room (with invite and
  // take-out) or holds a role in a public one.
  // A member's standing at a glance: green here, yellow here but away,
  // gray not here.  The title says it in words for a screen reader.
  function statusDot(online, away) {
    const state = online ? (away ? 'away' : 'online') : 'off';
    const dot = el('span', 'dot ' + state);
    dot.title = state === 'online' ? t('Online') : state === 'away' ? t('Away') : t('Not here');
    return dot;
  }

  async function openMembers() {
    const info = S.info;
    const box = openPanel(t('People'), 'members');
    box.appendChild(el('h4', '', S.here.length ? t('Here now') : t('Nobody else is here right now')));
    const here = el('div', 'memberlist');
    for (const p of S.here) {
      const who = link('/u/' + enc(p.name), 'who');
      who.append(avatar(p.name, p.avatar, 'small' + (p.away ? ' away' : '')), statusDot(true, p.away), el('span', '', p.name));
      const row = el('div', 'person');
      row.appendChild(who);
      if (p.away) row.appendChild(el('span', 'role', t('away')));
      here.appendChild(row);
    }
    box.appendChild(here);
    box.appendChild(el('h4', '', info.private ? t('In this channel') : t('Channel moderators')));
    const list = el('div', 'memberlist');
    box.appendChild(list);
    const show = async function () {
      try {
        const people = await get('/api/room/members?room=' + enc(info.slug));
        list.replaceChildren();
        if (!people.length) list.appendChild(el('p', 'notice', info.owner ?
          t('%s owns this channel. Nobody else holds a role in it.', info.owner) :
          t('Nobody holds a role in this channel. Site moderators look after it.')));
        for (const p of people) {
          const row = el('div', 'person');
          const who = link('/u/' + enc(p.name), 'who');
          who.append(avatar(p.name, p.avatar, 'small' + (p.away ? ' away' : '')), statusDot(p.online, p.away), el('span', '', p.name));
          row.appendChild(who);
          if (p.owner) row.appendChild(el('span', 'role', t('owner')));
          if (p.roles) row.appendChild(el('span', 'role', p.roles.replace('room-moderator', t('moderator'))));
          if (info.private && mayHere('kick') && !p.owner && p.name !== Me.name) {
            const out = el('button', 'small-link', t('Take out'));
            out.type = 'button';
            out.addEventListener('click', async function () {
              await command('/kick ' + p.name);
              show();
            });
            row.appendChild(out);
          }
          list.appendChild(row);
        }
      } catch (err) { failed(err); }
    };
    await show();
    if (info.private && mayHere('invite')) {
      const form = el('form', 'invite');
      const name = el('input');
      name.placeholder = t('Invite someone by name');
      const go = el('button', 'primary', t('Invite'));
      form.append(name, go);
      form.addEventListener('submit', async function (e) {
        e.preventDefault();
        if (!name.value.trim()) return;
        await command('/invite ' + name.value.trim());
        name.value = '';
        show();
      });
      box.appendChild(form);
    }
    box.appendChild(el('p', 'hint', info.private ?
      t('Commands work too: /invite name, /kick name, /op name makes a channel moderator.') :
      t('The owner names channel moderators with /op name. /mute name [minutes] quiets someone here.')));
  }

  // Runs a slash command in the open room, showing its answer as a toast.
  async function command(text) {
    try {
      const answer = JSON.parse(await post('/api/post', {room: S.room, body: text}));
      if (answer.info) toast(answer.info);
      syncNow();
    } catch (err) { failed(err); }
  }

  // Opening a room: public channels for those allowed, private rooms for
  // members.
  function newRoom() {
    const box = openPanel(t('Open a channel'), 'newroom');
    body.classList.remove('menu');
    const form = el('form', 'settings');
    const nameLabel = el('label');
    nameLabel.appendChild(el('span', '', t('Name')));
    const name = el('input');
    name.placeholder = t('lowercase-with-hyphens');
    name.maxLength = 40;
    nameLabel.appendChild(name);
    const topicLabel = el('label');
    topicLabel.appendChild(el('span', '', t('What it is for')));
    const topic = el('input');
    topicLabel.appendChild(topic);
    const kind = el('label', 'check');
    const priv = el('input');
    priv.type = 'checkbox';
    priv.checked = !may('create-channel');
    priv.disabled = !may('create-channel') || !may('create-private');
    kind.append(priv, document.createTextNode(t(' Private: only people invited see it')));
    const go = el('button', 'primary', t('Open it'));
    form.append(nameLabel, topicLabel, kind, go);
    box.appendChild(form);
    name.focus();
    name.addEventListener('input', function () {
      name.value = name.value.toLowerCase().replace(/[^a-z0-9-]+/g, '-');
    });
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      try {
        const made = JSON.parse(await post('/api/room/create', {slug: name.value.replace(/^-+|-+$/g, ''),
          topic: topic.value, private: priv.checked ? '1' : '0'}));
        roomsWanted = true;
        route('/p/' + enc(made.slug), true);
      } catch (err) { failed(err); }
    });
  }

  function openSearch() {
    const box = openPanel(t('Search'), 'search');
    const input = el('input');
    input.type = 'search';
    input.placeholder = t('Words to find');
    const scope = el('label', 'scope');
    const only = el('input');
    only.type = 'checkbox';
    const inDm = S.view === 'dm', withName = S.dm;
    only.checked = S.view === 'room' || inDm;
    scope.append(only, document.createTextNode(inDm ? t(' only in this conversation') : t(' only in this channel')));
    const results = el('div', 'threadlist');
    box.append(input, scope, results);
    // the server finds words only in what it can read
    if (inDm && S.dmLocked) box.insertBefore(el('p', 'notice', t('Locked messages are not searched: the server cannot read them.')), results);
    input.focus();
    let timer = 0;
    const run = async function () {
      const q = input.value.trim();
      if (q.length < 2) { results.replaceChildren(); return; }
      try {
        if (inDm && only.checked) {
          const found = await get('/api/dm/search?with=' + enc(withName) + '&q=' + enc(q));
          results.replaceChildren();
          if (!found.length) results.appendChild(el('p', 'notice', t('Nothing found.')));
          for (const m of found.reverse()) {
            const node = renderDm(m, await openSealed(m));
            node.classList.add('result');
            const bar = node.querySelector('.actions');
            if (bar) bar.remove();
            node.addEventListener('click', function (e) {
              if (e.target.closest('a, button')) return;
              const there = stream.querySelector('.msg[data-id="' + m.id + '"]');
              if (!there || S.dm !== withName) { toast(t('That message is further back.')); return; }
              there.scrollIntoView({block: 'center'});
              there.classList.add('flash');
              setTimeout(function () { there.classList.remove('flash'); }, 1600);
            });
            results.appendChild(node);
          }
          return;
        }
        const list = await get('/api/search?q=' + enc(q) + (only.checked && !inDm ? '&room=' + enc(S.room) : ''));
        results.replaceChildren();
        if (!list.length) results.appendChild(el('p', 'notice', t('Nothing found.')));
        for (const m of list) {
          const node = renderMessage(m, true);
          node.classList.add('result');
          node.addEventListener('click', function (e) {
            if (e.target.closest('a, button')) return;
            route('/m/' + m.id, true);
          });
          results.appendChild(node);
        }
      } catch (err) { failed(err); }
    };
    input.addEventListener('input', function () { clearTimeout(timer); timer = setTimeout(run, 300); });
    only.addEventListener('change', run);
  }

  // ------------------------------------------------------------- the card

  // What other scripts show over a room's messages.
  function renderCard(info) {
    const card = $('#card');
    card.replaceChildren();
    for (const show of Extras.cards) show(info, card);
  }

  // --------------------------------------------------------------- composer

  function fit(area) {
    area.style.height = 'auto';
    area.style.height = Math.min(area.scrollHeight, 300) + 'px';
  }

  // True while the caret sits inside an open ``` block, where Enter makes a new line.
  function inFence(area) {
    return (area.value.slice(0, area.selectionStart).match(/```/g) || []).length % 2 === 1;
  }

  async function upload(file, expire, sealedFor) {
    if (sealedFor) return Keys.sealFile(sealedFor, file, expire);
    const form = new FormData();
    form.append('expire', expire || '');
    form.append('file', file, file.name || 'pasted.png');
    return JSON.parse(await post('/api/upload', form));
  }

  // Until the address is confirmed: the way to another link, or to fix a
  // mistyped address.
  function confirmBox() {
    const form = el('form', 'confirmbox');
    const email = el('input');
    email.type = 'email';
    email.placeholder = t('A different address (or leave it)');
    const again = el('button', 'primary', t('Send the link again'));
    form.append(el('p', 'notice', t('Confirm your email to talk: open the link we mailed you. It can take a minute, and it may be in the spam folder.')), email, again);
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      try { toast(await post('/api/verify', {email: email.value.trim()})); } catch (err) { failed(err); }
    });
    return form;
  }

  // The box members type in, for a room, a thread (parent) or a private
  // conversation (dm).
  const Drafts = new Map();

  function renderComposer(area, parent, dm) {
    area.replaceChildren();
    if (!Me.name) {
      area.appendChild(joinForm(t('Pick a name and a password to join the conversation.')));
      return;
    }
    if (Me.verified === false) {
      area.appendChild(confirmBox());
      return;
    }
    if (!parent && !dm && S.info && !S.info.can_start) {
      area.appendChild(el('p', 'notice', S.info.why_not));
      return;
    }
    const form = el('form', 'composer');
    const files = el('div', 'attachments');
    const row = el('div', 'box');
    const attach = iconButton('attach', t('Attach a file (or paste or drop one)'));
    const area2 = el('textarea');
    area2.rows = 1;
    area2.maxLength = 8000;
    area2.placeholder = dm ? t('Private message to %s', dm) : parent ? t('Reply in the thread') :
      S.info && S.info.kind === 'shelf' ? t('Put something on your shelf') : t('Message %s', S.info ? roomTitle(S.info) : '');
    // What was typed and not sent waits here for the next visit.
    const draftKey = dm ? 'dm ' + dm : parent ? 'thread ' + parent : 'room ' + S.room;
    area2.value = Drafts.get(draftKey) || '';
    const code = iconButton('code', t('Code block'));
    const send = el('button', 'send', t('Send'));
    row.append(attach, area2, code);
    const answering = el('div', 'answering');
    answering.hidden = true;
    if (dm) {
      S.showDmReply = function () {
        answering.replaceChildren();
        answering.hidden = !S.dmReply;
        if (!S.dmReply) return;
        const stop = iconButton('close', t('Do not answer it after all'));
        stop.addEventListener('click', function () { S.dmReply = null; S.showDmReply(); area2.focus(); });
        answering.append(el('span', '', t('Answering %s:', S.dmReply.from) + ' ' + S.dmReply.text), stop);
        area2.focus();
      };
      S.showDmReply();
    }
    if (dm) {
      const beam = iconButton('beam', t('Beam a file: straight to them, never stored here'));
      beam.addEventListener('click', function () { beamPick.click(); });
      row.appendChild(beam);
    }
    row.appendChild(send);
    const filePick = el('input');
    filePick.type = 'file';
    filePick.multiple = true;
    filePick.hidden = true;
    const beamPick = el('input');
    beamPick.type = 'file';
    beamPick.hidden = true;
    const options = el('div', 'options');
    const expire = el('select');
    [['', t('Keep files')], ['hour', t('Delete after an hour')], ['day', t('Delete after a day')],
      ['week', t('Delete after a week')], ['once', t('Delete after one download')]].forEach(function (o) {
      const opt = el('option', '', o[1]);
      opt.value = o[0];
      expire.appendChild(opt);
    });
    options.appendChild(expire);
    options.appendChild(el('span', 'hints', t('Enter sends · Shift+Enter new line · ``` for code · / for commands')));
    form.append(answering, files, row, options, filePick, beamPick);
    area.appendChild(form);
    const pending = [];
    // each upload's chip, apart from the upload itself, which may be sent as it is
    const chips = new Map();

    const add = async function (list) {
      for (const file of list) {
        const chip = el('span', 'chip busy', file.name || t('picture'));
        files.appendChild(chip);
        try {
          const done = await upload(file, expire.value, dm && S.dmLocked ? dm : '');
          pending.push(done);
          chips.set(done, chip);
          chip.classList.remove('busy');
          const x = el('button', '', '×');
          x.type = 'button';
          x.addEventListener('click', function () { pending.splice(pending.indexOf(done), 1); chip.remove(); });
          chip.appendChild(x);
        } catch (err) {
          chip.remove();
          failed(err);
        }
      }
    };

    attach.addEventListener('click', function () { filePick.click(); });
    filePick.addEventListener('change', function () { add(Array.from(filePick.files)); filePick.value = ''; });
    beamPick.addEventListener('change', function () {
      if (beamPick.files[0]) beamFile(dm, beamPick.files[0]);
      beamPick.value = '';
    });
    area2.addEventListener('paste', function (e) {
      const list = Array.from(e.clipboardData.files || []);
      if (list.length) { e.preventDefault(); add(list); }
    });
    form.addEventListener('dragover', function (e) { e.preventDefault(); form.classList.add('drop'); });
    form.addEventListener('dragleave', function () { form.classList.remove('drop'); });
    form.addEventListener('drop', function (e) {
      e.preventDefault();
      form.classList.remove('drop');
      add(Array.from(e.dataTransfer.files));
    });
    code.addEventListener('click', function () {
      const at = area2.selectionStart;
      const selected = area2.value.slice(at, area2.selectionEnd);
      area2.setRangeText('```\n' + selected + '\n```', at, area2.selectionEnd, 'end');
      area2.selectionStart = area2.selectionEnd = at + 4 + selected.length;
      area2.focus();
      fit(area2);
    });

    const complete = completer(area2);

    let sending = false;
    const submit = async function () {
      const text = area2.value.trim();
      if (!text && !pending.length) return;
      // Enter again while it goes would send it twice
      if (sending) return;
      Drafts.delete(draftKey);
      // The commands the page does itself: a private message is encrypted
      // here, so the server never sees one.
      const word = text.match(/^\/(\w+)\s*([\s\S]*)$/);
      if (word && Extras.commands[word[1]]) {
        area2.value = '';
        fit(area2);
        Extras.commands[word[1]](word[2]);
        return;
      }
      const local = text.match(/^\/(msg|query)\b\s*@?([\w.-]*)\s*([\s\S]*)$/);
      if (local) {
        area2.value = '';
        fit(area2);
        if (!local[2]) { note(t('Use: /msg name text'), parent); return; }
        await route('/dm/' + enc(local[2]), true);
        if (local[3] && S.view === 'dm') {
          try { await sendDm(S.dm, local[3], []); } catch (err) { failed(err); }
        }
        return;
      }
      send.disabled = true;
      sending = true;
      // what goes now; what is typed or uploaded while it goes stays for the next
      const sent = pending.slice();
      try {
        if (dm) await sendDm(dm, text, sent);
        else {
          const answer = JSON.parse(await post('/api/post', {room: S.room, parent: parent || '',
            body: text, files: sent.map(function (p) { return p.token; }).join(',')}));
          if (answer.info) note(answer.info, parent);
          if (answer.go) {
            area2.value = '';
            send.disabled = false;
            if (answer.info) toast(answer.info);
            // After /part the room is gone from the sidebar.
            if (answer.go === '/') S.rooms = S.rooms.filter(function (r) { return r.slug !== S.room; });
            roomsWanted = true;
            route(answer.go, true);
            return;
          }
        }
        if (area2.value.trim() === text) area2.value = '';
        for (const p of sent) {
          const at = pending.indexOf(p);
          if (at >= 0) pending.splice(at, 1);
          if (chips.has(p)) { chips.get(p).remove(); chips.delete(p); }
        }
        fit(area2);
        if (!dm) syncNow(text.startsWith('/'));
      } catch (err) { failed(err); }
      finally { sending = false; }
      send.disabled = false;
      area2.focus();
    };

    form.addEventListener('submit', function (e) { e.preventDefault(); submit(); });
    area2.addEventListener('keydown', function (e) {
      if (complete.handle(e)) return;
      if (e.key === 'Enter' && !e.shiftKey && !inFence(area2)) { e.preventDefault(); submit(); }
      if (e.key === 'ArrowUp' && !area2.value && dm) {
        const mine = Array.from(stream.querySelectorAll('.msg')).filter(function (x) {
          return x.dm && x.dm.m.from === Me.name && (x.dm.payload.t === 'text' || x.dm.payload.t === 'file');
        });
        if (mine.length) { e.preventDefault(); startDmEdit(mine[mine.length - 1]); }
      } else if (e.key === 'ArrowUp' && !area2.value) {
        const mine = Array.from((parent ? S.threadMessages : S.messages).values())
          .filter(function (x) { return x.data.name === Me.name && !x.data.deleted && x.data.uid; });
        if (mine.length) { e.preventDefault(); startEdit(mine[mine.length - 1].data); }
      }
    });
    area2.addEventListener('input', function () {
      Drafts.set(draftKey, area2.value);
      fit(area2);
      complete.update();
      if (Date.now() - S.typingSent > 3000 && area2.value) {
        S.typingSent = Date.now();
        if (dm) post('/api/dm/typing', {to: dm}).catch(function () { });
        else post('/api/typing', {room: S.room}).catch(function () { });
      }
    });
    fit(area2);
    if (!parent) area2.focus();
  }

  // A note only this member sees, such as /help's answer.
  function note(text, inThread) {
    const box = inThread ? $('.threadlist', panel) : stream;
    const n = el('div', 'note');
    n.appendChild(el('pre', '', text));
    const x = el('button', '', t('Dismiss'));
    x.type = 'button';
    x.addEventListener('click', function () { n.remove(); });
    n.appendChild(x);
    box.appendChild(n);
    box.scrollTop = box.scrollHeight;
  }

  // Suggestions for @member, #room and /command as they are typed.
  function completer(area) {
    const box = el('div', 'complete');
    box.hidden = true;
    area.closest('.composer').appendChild(box);
    let items = [];
    let index = 0;
    let start = 0;

    const word = function () {
      const before = area.value.slice(0, area.selectionStart);
      const m = before.match(/(^|\s)([@#])([\w.-]*)$/) || before.match(/^(\/)([\w]*)$/);
      if (!m) return null;
      if (m[1] === '/') return {kind: '/', text: m[2], at: 0};
      return {kind: m[2], text: m[3], at: before.length - m[3].length - 1};
    };

    const show = function (list) {
      items = list.slice(0, 8);
      index = 0;
      box.replaceChildren();
      box.hidden = !items.length;
      items.forEach(function (it, i) {
        const row = el('div', 'item' + (i === 0 ? ' on' : ''));
        row.appendChild(el('b', '', it.label));
        if (it.hint) row.appendChild(el('span', '', it.hint));
        row.addEventListener('mousedown', function (e) { e.preventDefault(); index = i; pick(); });
        box.appendChild(row);
      });
    };

    const pick = function () {
      const it = items[index];
      if (!it) return;
      area.setRangeText(it.insert, start, area.selectionStart, 'end');
      box.hidden = true;
      items = [];
      area.focus();
    };

    let timer = 0;
    const update = function () {
      const w = word();
      clearTimeout(timer);
      if (!w) { box.hidden = true; items = []; return; }
      start = w.at;
      timer = setTimeout(async function () {
        try {
          if (w.kind === '@') {
            const list = await get('/api/users?q=' + enc(w.text));
            show(list.map(function (u) { return {label: '@' + u.name, insert: '@' + u.name + ' '}; }));
          } else if (w.kind === '#') {
            let all = S.rooms.filter(function (r) { return r.kind !== 'shelf'; }).map(function (r) { return {slug: r.slug, title: r.title}; });
            for (const more of Extras.rooms) all = all.concat(await more(w.text));
            const seen = {};
            show(all.filter(function (r) {
              if (seen[r.slug] || !r.slug.startsWith(w.text.toLowerCase())) return false;
              seen[r.slug] = true;
              return true;
            }).map(function (r) { return {label: '#' + r.slug, hint: r.title, insert: '#' + r.slug + ' '}; }));
          } else {
            if (!S.commands) S.commands = await get('/api/commands');
            show(S.commands.filter(function (c) { return c.name.startsWith(w.text.toLowerCase()); })
              .map(function (c) { return {label: '/' + c.name, hint: c.usage, insert: '/' + c.name + ' '}; }));
          }
        } catch (err) { box.hidden = true; }
      }, w.kind === '@' ? 150 : 0);
    };

    const handle = function (e) {
      if (box.hidden || !items.length) return false;
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        index = (index + (e.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length;
        Array.from(box.children).forEach(function (c, i) { c.classList.toggle('on', i === index); });
        return true;
      }
      if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); pick(); return true; }
      if (e.key === 'Escape') { box.hidden = true; return true; }
      return false;
    };
    area.addEventListener('blur', function () { setTimeout(function () { box.hidden = true; }, 150); });
    return {update: update, handle: handle};
  }

  // ------------------------------------------------------- private messages

  // Private messages are encrypted, so their text is shaped here: code
  // blocks, inline code, bold and links, everything else escaped.
  function plainHtml(text, locked) {
    const esc = function (s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); };
    return text.split('```').map(function (part, i) {
      if (i % 2) return '<div class="code"><div class="codebar"><span>' + esc((/^([\w+#-]+)\n/.exec(part) || ['', t('code')])[1]) + '</span>' +
        (locked ? '<span class="codenote">' + esc(t('Not colored: the server cannot read a locked conversation.')) + '</span>' : '') + '<button type="button" class="copy">' + esc(t('Copy')) + '</button></div><pre><code>' +
        esc(part.replace(/^[\w+#-]*\n/, '').replace(/\n$/, '')) + '</code></pre></div>';
      return esc(part).replace(/`([^`\n]+)`/g, '<code>$1</code>').replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')
        .replace(/(https?:\/\/[^\s<]+)/g, '<a rel="nofollow ugc" target="_blank" href="$1">$1</a>').replace(/\n/g, '<br>');
    }).join('');
  }

  async function openDm(name) {
    const generation = S.generation;
    const who = await get('/api/key?name=' + enc(name));
    if (generation !== S.generation) return;
    S.view = 'dm';
    if (S.dm !== who.name) S.dmReply = null;
    S.dm = who.name;
    S.dmAvatar = who.avatar;
    S.dmLast = 0;
    S.dmFirst = 0;
    S.dmOlderDone = false;
    S.title = '@' + who.name;
    const head = $('#roomhead');
    const menu = iconButton('menu', t('Channels'), 'menubtn');
    menu.addEventListener('click', toggleMenu);
    const titles = el('div', 'titles');
    const h = el('h1');
    h.append(avatar(who.name, who.avatar, 'small'), link('/u/' + enc(who.name), '', who.name));
    titles.appendChild(h);
    S.dmLocked = !!who.locked;
    const lock = el('p', 'topic' + (S.dmLocked ? ' secure' : ''));
    if (S.dmLocked) lock.append(icon('lock'), document.createTextNode(t(' Locked: end to end encrypted. Only your two browsers can read it, and IRC users cannot.')));
    else lock.appendChild(document.createTextNode(t('Not locked: this site can read it, and it reaches IRC. ')));
    if (Me.name) {
      const flip = el('button', 'small-link', S.dmLocked ? t('Unlock') : t('Lock it'));
      flip.type = 'button';
      flip.title = S.dmLocked ? t('New messages go plain, readable by this site and on IRC') :
        t('New messages are encrypted in your browsers; neither this site nor IRC can read them');
      flip.addEventListener('click', async function () {
        try { await post('/api/dm/lock', {with: who.name, on: S.dmLocked ? '0' : '1'}); route(location.pathname, false); } catch (err) { failed(err); }
      });
      lock.appendChild(flip);
    }
    titles.appendChild(lock);
    head.append(menu, titles);
    if (Me.name) {
      // The same as the arrow on its row in the room list, where a phone
      // hides it.
      const tools = el('div', 'headtools');
      const remove = iconButton('trash', t('Delete this conversation'));
      remove.addEventListener('click', function () { deleteDm(who.name); });
      const find = iconButton('search', t('Search'));
      find.addEventListener('click', openSearch);
      tools.append(find, remove);
      head.appendChild(tools);
    }
    if (!Me.name) {
      stream.appendChild(el('p', 'notice', t('Sign in to send private messages.')));
      renderComposer($('#composer-area'), 0, null);
      return;
    }
    if (!Keys.ready()) {
      stream.appendChild(el('p', 'notice', t('Private messages need this page opened over https.')));
      return;
    }
    if (S.dmLocked && !await Keys.myKey()) {
      stream.appendChild(keyForm());
      return;
    }
    renderComposer($('#composer-area'), 0, who.name);
    pollDm(generation);
    syncNow(true);
  }

  // Signed in with GitHub, GitLab or Google: the private key opens with the
  // account's password, or the account gets its first one here.
  function keyForm() {
    const first = !Me.wrapped;
    const form = el('form', 'invite keyform');
    const password = el('input');
    password.type = 'password';
    password.autocomplete = first ? 'new-password' : 'current-password';
    password.placeholder = first ? t('A new password, 8 characters or more') : t('Your password');
    const go = el('button', 'primary', first ? t('Set it') : t('Unlock'));
    let say = t('Type your password to open your locked messages on this device.');
    if (first && Me.password) say = t('Locked conversations need a key made from your password. Type it once here.');
    else if (first) say = t('Locked conversations need a password that never leaves your browser, and this account has none yet. Set one here. It also signs you in with your name, and a forgotten one cannot be reset.');
    form.append(el('p', 'notice', say), password, go);
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      go.disabled = true;
      try {
        if (first) await Keys.setupKeys(Me.name, password.value);
        else await Keys.unlock(Me.name, password.value, Me.wrapped);
        route(location.pathname, false);
      } catch (err) { failed(err); }
      go.disabled = false;
    });
    return form;
  }

  async function openSealed(m) {
    if (!m.iv) {
      try { return JSON.parse(m.data); } catch (err) { return {t: 'text', text: m.data}; }
    }
    try { return await Keys.open(S.dm, m); } catch (err) { return {t: 'text', text: t('(locked, and this device cannot open it)')}; }
  }

  // The newest messages first; a live ring or the timer brings newer ones.
  async function pollDm(generation) {
    if (generation !== S.generation) return;
    clearTimeout(S.dmTimer);
    try {
      const list = await get('/api/dm?with=' + enc(S.dm) + '&after=' + S.dmLast);
      if (generation !== S.generation) return;
      const stick = stream.pinned || nearBottom() || !S.dmLast;
      for (const m of list) {
        const payload = await openSealed(m);
        // A second look that started before this one finished has it already.
        if (generation !== S.generation || m.id <= S.dmLast) continue;
        stream.appendChild(renderDm(m, payload));
        S.dmLast = Math.max(S.dmLast, m.id);
        if (!S.dmFirst || m.id < S.dmFirst) S.dmFirst = m.id;
      }
      if (list.length) {
        regroup(stream);
        if (stick) { stream.scrollTop = stream.scrollHeight; stream.pinned = true; }
      }
      if (!list.length && !S.dmLast && !$('.empty', stream)) {
        const p = el('div', 'empty');
        p.appendChild(el('b', '', t('Nothing between you two yet.')));
        p.appendChild(el('span', '', S.dmLocked ? t(' Locked: only the two of you will ever read what you write here.') :
          t(' Lock it at the top when it should stay between your two browsers.')));
        stream.appendChild(p);
      } else if (list.length && $('.empty', stream)) $('.empty', stream).remove();
    } catch (err) { }
    S.dmTimer = setTimeout(function () { pollDm(generation); }, Live.id ? 60000 : document.hidden ? 15000 : 3000);
  }

  // Scrolling to the top of a private conversation brings older messages.
  async function olderDms() {
    if (!S.dmFirst || S.dmOlderDone || S.loadingOlder) return;
    S.loadingOlder = true;
    const generation = S.generation;
    try {
      const list = await get('/api/dm?with=' + enc(S.dm) + '&before=' + S.dmFirst);
      if (generation !== S.generation) return;
      const height = stream.scrollHeight;
      const top = stream.querySelector('.msg');
      for (const m of list) {
        const node = renderDm(m, await openSealed(m));
        if (top) top.before(node); else stream.appendChild(node);
      }
      if (list.length) S.dmFirst = list[0].id;
      if (list.length < 100) S.dmOlderDone = true;
      regroup(stream);
      stream.scrollTop = stream.scrollHeight - height;
    } catch (err) { failed(err); }
    finally { S.loadingOlder = false; }
  }

  // A private message taken back, by this member or the other: out of the
  // open conversation, the groups redone.
  function dropDm(id) {
    const node = stream.querySelector('.msg[data-id="' + id + '"]');
    if (!node) return;
    node.remove();
    regroup(stream);
  }

  // One's own private message written again: the same box as in a channel.
  // The payload keeps its kind and files; a locked conversation seals it again.
  function startDmEdit(node) {
    const m = node.dm.m, payload = node.dm.payload;
    const text = node.querySelector('.body');
    if (!text) return;
    const box = el('div', 'editbox');
    const area = el('textarea');
    area.value = payload.text || '';
    const save = el('button', 'primary', t('Save'));
    const cancel = el('button', '', t('Cancel'));
    save.type = cancel.type = 'button';
    box.append(area, save, cancel);
    text.replaceWith(box);
    area.focus();
    area.setSelectionRange(area.value.length, area.value.length);
    fit(area);
    const done = function () { box.replaceWith(text); };
    const store = async function () {
      const body = area.value.trim();
      if (!body && !(payload.files && payload.files.length)) {
        failed(new Error(t('An edited message cannot be empty. Delete it instead.')));
        return;
      }
      if (body === (payload.text || '')) { done(); return; }
      try {
        await post('/api/dm/edit', Object.assign({id: m.id}, await dmData(S.dm, Object.assign({}, payload, {text: body}))));
        done();
        refreshDm(m.id);
      } catch (err) { failed(err); }
    };
    save.addEventListener('click', store);
    cancel.addEventListener('click', done);
    area.addEventListener('input', function () { fit(area); });
    area.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') done();
      if (e.key === 'Enter' && !e.shiftKey && !inFence(area)) { e.preventDefault(); store(); }
    });
  }

  // A private message changed, here or on the other side: shown again in place.
  async function refreshDm(id) {
    const node = stream.querySelector('.msg[data-id="' + id + '"]');
    if (!node || S.view !== 'dm') return;
    const generation = S.generation;
    try {
      const list = await get('/api/dm?with=' + enc(S.dm) + '&id=' + id);
      if (generation !== S.generation || !list.length) return;
      const fresh = renderDm(list[0], await openSealed(list[0]));
      const now = stream.querySelector('.msg[data-id="' + id + '"]');
      if (now) { now.replaceWith(fresh); regroup(stream); }
    } catch (err) { }
  }

  function renderDm(m, payload) {
    // the other side wrote the payload: what is not the expected shape is left out
    if (!payload || typeof payload !== 'object') payload = {};
    if (typeof payload.text !== 'string') payload.text = '';
    if (!Array.isArray(payload.files)) delete payload.files;
    const node = renderMessage({id: m.id, at: m.at, name: m.from, uid: 1, html: '', room: S.room,
      avatar: m.from === Me.name ? Me.avatar : S.dmAvatar, edited: !!m.edited, dm: true,
      files: [], reactions: Array.isArray(m.reactions) ? m.reactions : [], replies: 0, deleted: false}, true);
    node.dm = {m: m, payload: payload};
    // Its own actions: react, answer, copy, and for one's own words, edit
    // and delete from both sides.
    const bar = node.querySelector('.actions');
    bar.replaceChildren();
    if (may('react')) {
      const r = iconButton('react', t('React'), 'reactbtn');
      r.addEventListener('click', function () { picker(r, m.id, true); });
      bar.appendChild(r);
    }
    if (payload.text) {
      const a = iconButton('reply', t('Answer this message'));
      a.addEventListener('click', function () {
        S.dmReply = {id: m.id, from: m.from, text: payload.text.replace(/```[\s\S]*?(```|$)/g, ' ').replace(/[*_~`]+/g, '').replace(/\s+/g, ' ').trim().slice(0, 140) || t('code')};
        if (S.showDmReply) S.showDmReply();
      });
      bar.appendChild(a);
    }
    if (payload.text) {
      const c = iconButton('copy', t('Copy the text'));
      c.addEventListener('click', function () {
        navigator.clipboard.writeText(payload.text).then(function () { toast(t('Text copied.')); });
      });
      bar.appendChild(c);
    }
    if (m.from === Me.name && (payload.t === 'text' || payload.t === 'file')) {
      const e = iconButton('edit', t('Edit'));
      e.addEventListener('click', function () { startDmEdit(node); });
      bar.appendChild(e);
    }
    if (m.from === Me.name) {
      const d = iconButton('trash', t('Delete, for both of you'));
      d.addEventListener('click', async function () {
        if (!confirm(t('Delete this message? It goes from both sides.'))) return;
        try { await post('/api/dm/delete', {id: m.id}); dropDm(m.id); } catch (err) { failed(err); }
      });
      bar.appendChild(d);
    }
    const text = node.querySelector('.body');
    // an unlocked message comes shaped by the server, like a channel's; a
    // locked one the server cannot read, so its few marks are shaped here
    if (!m.iv && typeof m.html === 'string') text.innerHTML = m.html;   // safe html: rendered by the server
    else text.innerHTML = plainHtml(payload.text || '', !!m.iv);   // safe html: plainHtml escapes everything first
    dressCode(text);
    // the message this one answers: the other side wrote these words, so
    // they are shown as text, never as HTML
    const re = payload.re;
    if (re && typeof re === 'object' && typeof re.text === 'string' && typeof re.from === 'string') {
      const quote = el('button', 'dmquote');
      quote.type = 'button';
      quote.append(el('b', '', re.from.slice(0, 60)), document.createTextNode(' ' + re.text.slice(0, 140)));
      quote.addEventListener('click', function () {
        const there = stream.querySelector('.msg[data-id="' + parseInt(re.id, 10) + '"]');
        if (!there) { toast(t('That message is further back.')); return; }
        there.scrollIntoView({block: 'center'});
        there.classList.add('flash');
        setTimeout(function () { there.classList.remove('flash'); }, 1600);
      });
      text.before(quote);
    }
    if (m.preview && typeof m.preview === 'object') text.after(previewOf(m.preview));
    if (payload.files) {
      const box = el('div', 'files');
      for (const f of payload.files) box.appendChild(f.iv ? sealedFile(f) : plainFile(f));
      text.after(box);
    }
    if (payload.t === 'beam') text.after(beamCard(m, payload));
    return node;
  }

  // The sender wrote this payload: only our own /f/ links get through.
  function plainFile(f) {
    if (!String(f.url).startsWith('/f/')) f = {name: String(f.name), size: 0, url: '#'};
    if (f.image) {
      const shot = link(f.url, 'shot');
      const img = el('img');
      img.src = f.url;
      img.loading = 'lazy';
      shot.appendChild(img);
      return shot;
    }
    const a = link(f.url, 'file');
    a.append(el('span', 'fname', f.name), el('span', 'fsize', sizeText(f.size)));
    return a;
  }

  function sealedFile(f) {
    const a = link('#', 'file');
    a.append(icon('lock'), el('span', 'fname', f.name), el('span', 'fsize', sizeText(f.size)));
    const open = async function (e) {
      if (e) e.preventDefault();
      try {
        const blob = await Keys.openFile(S.dm, f);
        const url = URL.createObjectURL(blob);
        if ((f.type || '').startsWith('image/')) {
          const shot = link(url, 'shot');
          const img = el('img');
          img.src = url;
          shot.appendChild(img);
          a.replaceWith(shot);
        } else {
          const save = link(url, '');
          save.download = f.name;
          save.click();
        }
      } catch (err) { failed(err); }
    };
    a.addEventListener('click', open);
    if ((f.type || '').startsWith('image/') && f.size < 8 * 1024 * 1024) setTimeout(open, 0);
    return a;
  }

  async function sendDm(other, text, files) {
    const payload = {t: files.length ? 'file' : 'text', text: text};
    if (files.length) payload.files = files;
    if (S.dmReply && S.dm === other) payload.re = S.dmReply;
    S.dmReply = null;
    if (S.showDmReply) S.showDmReply();
    await post('/api/dm', Object.assign({to: other, files: files.map(function (f) { return f.token; }).join(',')},
      await dmData(other, payload)));
    pollNow();
  }

  // What /api/dm takes: sealed when the conversation is locked, plain JSON when not.
  async function dmData(other, payload) {
    if (!S.dmLocked) return {data: JSON.stringify(payload)};
    const sealed = await Keys.seal(other, payload);
    return {iv: sealed.iv, data: sealed.data};
  }

  function pollNow() {
    clearTimeout(S.dmTimer);
    pollDm(S.generation);
  }

  // Beam: the sender keeps the page open while the file goes across.
  async function beamFile(other, file) {
    try {
      let token = '';
      token = await Keys.beamSend(other, file, function (done, total, state) {
        if (S.beams[token]) S.beams[token](done, total, state);
      });
      await post('/api/dm', Object.assign({to: other},
        await dmData(other, {t: 'beam', name: file.name, size: file.size, token: token})));
      toast(t('Keep this page open until %s has the file.', other));
      pollNow();
    } catch (err) {
      note(t('The beam did not start: %s', err.message || err));
    }
  }

  function beamCard(m, payload) {
    const card = el('div', 'beam');
    card.appendChild(icon('beam'));
    card.appendChild(el('b', '', payload.name));
    card.appendChild(el('span', 'fsize', sizeText(payload.size)));
    const bar = el('progress');
    bar.max = 1;
    bar.value = 0;
    const state = el('span', 'state');
    const report = function (done, total, what) {
      bar.max = total || 1;
      bar.value = done;
      state.textContent = {waiting: t('waiting for them to take it'), sending: t('sending'),
        receiving: t('receiving'), connecting: t('connecting'), done: t('delivered')}[what] || what;
    };
    if (m.from === Me.name) {
      S.beams[payload.token] = report;
      state.textContent = t('sent from this page, which has to stay open');
      card.append(bar, state);
    } else {
      const take = el('button', 'primary', t('Take it'));
      take.type = 'button';
      take.addEventListener('click', async function () {
        take.remove();
        card.append(bar, state);
        try {
          const got = await Keys.beamReceive(payload.token, report);
          state.textContent = t('received');
          const save = link(URL.createObjectURL(got), 'primary', t('Save %s', got.name));
          save.download = got.name;
          card.appendChild(save);
          save.click();
        } catch (err) { state.textContent = err.message; }
      });
      card.appendChild(take);
      card.appendChild(el('span', 'state', t('straight from their browser, never stored on the server')));
    }
    return card;
  }

  // ---------------------------------------------------------------- profile

  // A private message and Ignore on someone else's profile
  function profileTools(who, tools) {
    if (Me.name && Me.name !== who.name) {
      tools.appendChild(link('/dm/' + enc(who.name), 'primary', t('Private message')));
      const ignore = el('button', '', who.ignored ? t('Stop ignoring') : t('Ignore'));
      ignore.type = 'button';
      ignore.title = t('Their messages fold away, and their mentions and private messages do not reach you');
      ignore.addEventListener('click', async function () {
        try {
          await post('/api/ignore', {name: who.name, on: who.ignored ? '0' : '1'});
          route(location.pathname, false);
        } catch (err) { failed(err); }
      });
      tools.appendChild(ignore);
    }
  }

  // What the member put up to stay, under the profile: a room of their own
  async function profileShelf(who, generation) {
    const shelfHead = el('div', 'shelfhead');
    shelfHead.append(icon('shelf'), el('b', '', t('%s’s shelf', who.name)),
      el('span', '', t('what they put up to stay: things they made, found or want to keep in view')));
    $('#card').appendChild(shelfHead);
    let info = null;
    try { info = await get('/api/room?slug=' + enc('~' + who.name.toLowerCase())); } catch (err) { }
    if (generation !== S.generation || !info) return;
    S.view = 'room';
    S.room = info.slug;
    S.info = info;
    stream.className = 'shelf';
    await loadMessages(generation);
    if (!S.messages.size) {
      const empty = $('.empty', stream);
      if (empty) empty.replaceWith(el('p', 'notice empty', Me.name === who.name ?
        t('Your shelf is empty. Put something here that should stay: a project, a screenshot, a favorite answer.') :
        t('Nothing on the shelf yet.')));
    }
    if (Me.name === who.name) renderComposer($('#composer-area'), 0);
    else if (Me.name) $('#composer-area').appendChild(el('p', 'notice', t('Reply to anything on the shelf in its thread.')));
    syncNow(true);
  }

  // ------------------------------------------------------------------ start

  C.parts.push({
    prepare: async function () {
      if (!Me.name) try { S.rooms = await get('/api/rooms'); } catch (err) { }
    },
    sidebar: renderSidebar,
    start: function () {
      if (Me.name && 'Notification' in window && Notification.permission === 'granted' && 'PushManager' in window) C.subscribePush();
      C.offerNotifications();
      connectLive();
    },
    sync: syncNow,
    view: async function (view, target, thread) {
      if (view === 'room') await openRoom(target, thread);
      else if (view === 'dm') await openDm(target);
      else return false;
      return true;
    },
    open: async function (parts) {
      if (parts[1] === 'p') await openRoom(parts[2], 0);
      else if (parts[1] === 'm') {
        const list = await get('/api/thread?id=' + enc(parts[2]));
        if (!list.length) throw new Error(t('That message is gone.'));
        const root = list[0].parent ? list[0].parent : list[0].id;
        await openRoom(list[0].room, root);
      } else if (parts[1] === 'dm') await openDm(parts[2]);
      else return false;
      return true;
    },
    profileTools: profileTools,
    profile: profileShelf
  });
})();
