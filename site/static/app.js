// The site's page: account, profiles, the side panel and the admin page,
// moving between them without reloading.  Everything it shows comes from
// the JSON API.  The parts of the suite that live on this page add
// themselves to Chat.parts (chat.js: rooms, threads, private conversations)
// and answer for their own addresses, the side list and the live updates.
(function () {
  'use strict';

  const body = document.body;
  const Me = {name: body.dataset.me || '', can: [], ignores: []};
  const Site = body.dataset.site;
  const Reactions = ['👍', '❤️', '😂', '🎉', '🤔', '👎'];
  const $ = function (s, root) { return (root || document).querySelector(s); };
  const stream = $('#stream');
  const panel = $('#panel');

  const S = {
    view: '', room: '', info: null, messages: new Map(), since: 0, lastRead: 0, divider: 0,
    oldest: Infinity, older: true, thread: 0, threadMessages: new Map(), generation: 0,
    rooms: [], dms: [], commands: null, typingSent: 0, tick: 0, alerts: {},
    dm: '', dmLast: 0, dmFirst: 0, dmTimer: 0, beams: {}, typers: {}, here: []
  };

  // What the member may do anywhere, from /api/me.
  function may(p) { return Me.can.indexOf(p) >= 0; }
  // What the member may do in the open room, from /api/room.
  function mayHere(p) { return !!(S.info && S.info.can && S.info.can[p]); }

  // ---------------------------------------------------------------- helpers

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function link(href, cls, text) {
    const a = el('a', cls, text);
    a.href = href;
    return a;
  }

  async function get(url) {
    const answer = await fetch(url);
    if (!answer.ok) throw new Error(await answer.text());
    return answer.json();
  }

  const post = Keys.post;

  function toast(text, kind) {
    const t = el('div', 'toast ' + (kind || ''), text);
    $('#toasts').appendChild(t);
    setTimeout(function () { t.classList.add('going'); }, 4500);
    setTimeout(function () { t.remove(); }, 5000);
  }

  // The last things that went wrong on this page, for a bug report.
  const Trail = [];
  function remember(what) {
    Trail.push(new Date().toISOString().slice(11, 19) + ' ' + what);
    if (Trail.length > 15) Trail.shift();
  }
  window.addEventListener('error', function (e) { remember('error: ' + e.message + ' (' + e.filename + ':' + e.lineno + ')'); });
  window.addEventListener('unhandledrejection', function (e) { remember('promise: ' + (e.reason && e.reason.message || e.reason)); });

  function failed(err) {
    remember('shown: ' + (err.message || String(err)));
    toast(err.message || String(err), 'bad');
  }

  // A color for a name: names that differ by one letter still look different.
  function hue(name) {
    let h = 2166136261;
    for (const c of name) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
    return (h >>> 0) % 360;
  }

  function avatar(name, url, cls) {
    const a = el('span', 'avatar ' + (cls || ''));
    if (url) {
      const img = el('img');
      img.src = url;
      img.alt = '';
      img.loading = 'lazy';
      a.appendChild(img);
    } else {
      a.textContent = (name || '?').charAt(0).toUpperCase();
      a.style.setProperty('--h', hue(name || '?'));
    }
    return a;
  }

  let locale;
  try { locale = Intl.getCanonicalLocales(document.documentElement.lang || '')[0]; } catch (err) { }

  function clock(at) {
    const d = new Date(at);
    return isNaN(d) ? at : d.toLocaleTimeString(locale, {hour: '2-digit', minute: '2-digit'});
  }

  function dayLabel(d) {
    const today = new Date();
    const yesterday = new Date(Date.now() - 86400000);
    if (d.toDateString() === today.toDateString()) return t('Today');
    if (d.toDateString() === yesterday.toDateString()) return t('Yesterday');
    if (d.getFullYear() !== today.getFullYear())
      return d.toLocaleDateString(locale, {weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'});
    return d.toLocaleDateString(locale, {weekday: 'long', month: 'long', day: 'numeric'});
  }

  function ago(iso) {
    if (!iso) return '';
    const minutes = Math.round((Date.now() - new Date(iso)) / 60000);
    if (minutes < 2) return t('just now');
    if (minutes < 60) return tn(minutes, '%d min ago', '%d min ago');
    if (minutes < 48 * 60) return tn(Math.round(minutes / 60), '%d hours ago', '%d hours ago');
    return tn(Math.round(minutes / 1440), '%d days ago', '%d days ago');
  }

  function sizeText(n) {
    if (n < 1024) return t('%d B', n);
    if (n < 1024 * 1024) return t('%d KB', Math.round(n / 1024));
    if (n < 1024 * 1024 * 1024) return t('%s MB', (n / 1024 / 1024).toFixed(1));
    if (n < 1024 * 1024 * 1024 * 1024) return t('%s GB', (n / 1024 / 1024 / 1024).toFixed(1));
    return t('%s TB', (n / 1024 / 1024 / 1024 / 1024).toFixed(2));
  }

  function nearBottom(box) {
    box = box || stream;
    return box.scrollHeight - box.scrollTop - box.clientHeight < 160;
  }

  // A list read at its bottom stays there when it gets shorter: a phone's
  // keyboard opening or the composer growing shrinks it without a scroll
  // event, and nearBottom would then miss the next message.
  const pinWatch = new ResizeObserver(function (entries) {
    for (const e of entries) {
      if (!e.target.isConnected) pinWatch.unobserve(e.target);
      else if (e.target.pinned && !e.target.noPin) e.target.scrollTop = e.target.scrollHeight;
    }
  });
  function keepPinned(box) {
    box.pinned = true;
    box.addEventListener('scroll', function () { box.pinned = !box.noPin && nearBottom(box); });
    pinWatch.observe(box);
  }
  keepPinned(stream);

  // A phone browser that ignores interactive-widget leaves the page its full
  // height under the keyboard; the page then takes the height shown.  Not
  // while zoomed in, where the shown part is smaller on purpose.
  if (window.visualViewport) {
    const fitShown = function () {
      const view = window.visualViewport;
      const root = document.documentElement;
      if (Math.abs(view.scale - 1) < 0.01 && view.height < root.clientHeight - 1) {
        root.style.setProperty('--shown-height', view.height + 'px');
        root.style.setProperty('--shown-top', view.offsetTop + 'px');
      } else {
        root.style.removeProperty('--shown-height');
        root.style.removeProperty('--shown-top');
      }
    };
    window.visualViewport.addEventListener('resize', fitShown);
    window.visualViewport.addEventListener('scroll', fitShown);
    fitShown();
  }

  function enc(s) { return encodeURIComponent(s); }

  const Icons = {
    react: 'M12 22a10 10 0 1 1 0-20 10 10 0 0 1 0 20zm-4-8a4.5 4.5 0 0 0 8 0M9 9.5h.01M15 9.5h.01',
    reply: 'M21 12a8 8 0 0 1-11.6 7.1L4 21l1.9-5.4A8 8 0 1 1 21 12z',
    link: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
    edit: 'M4 20h4L19 9l-4-4L4 16v4zM14 6l4 4',
    trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
    pin: 'M9 4h6l-1 6 4 4H6l4-4-1-6zM12 14v7',
    attach: 'M21 11l-8.5 8.5a5 5 0 0 1-7-7L14 4a3.5 3.5 0 0 1 5 5l-8.5 8.5a2 2 0 0 1-3-3L15 7',
    code: 'M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16',
    beam: 'M4 12h11M11 6l6 6-6 6M20 4v16',
    close: 'M6 6l12 12M18 6L6 18',
    menu: 'M4 6h16M4 12h16M4 18h16',
    search: 'M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14zM20 20l-4-4',
    lock: 'M6 11h12v9H6zM8 11V8a4 4 0 0 1 8 0v3',
    shelf: 'M4 6h16M4 12h16M4 18h16M6 6v12M18 6v12',
    bell: 'M6 16V11a6 6 0 0 1 12 0v5l2 2H4l2-2zM10 20a2 2 0 0 0 4 0',
    sun: 'M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10zM12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4',
    moon: 'M21 13A9 9 0 1 1 11 3a7 7 0 0 0 10 10z',
    auto: 'M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18zM12 3v18',
    people: 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21v-1a6 6 0 0 1 12 0v1M17 11a3 3 0 1 0 0-6M22 21v-1a5 5 0 0 0-4-4.9',
    plus: 'M12 5v14M5 12h14',
    copy: 'M8 8h12v12H8zM4 16V4h12',
    bug: 'M9 7a3 3 0 0 1 6 0M7 10h10v5a5 5 0 0 1-10 0zM12 10v10M4 13h3M17 13h3M5 8l2 2M19 8l-2 2M5 19l2-2M19 19l-2-2',
    install: 'M12 4v11M7 10l5 5 5-5M5 20h14',
    up: 'M6 15l6-6 6 6',
    down: 'M6 9l6 6 6-6'
  };

  function icon(name) {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('class', 'icon');
    const path = document.createElementNS(ns, 'path');
    path.setAttribute('d', Icons[name]);
    svg.appendChild(path);
    return svg;
  }

  function iconButton(name, title, cls) {
    const b = el('button', 'iconbtn ' + (cls || ''));
    b.type = 'button';
    b.title = title;
    b.setAttribute('aria-label', title);
    b.appendChild(icon(name));
    return b;
  }

  // ------------------------------------------------------------------ theme

  const themeButton = $('#theme');
  function showTheme() {
    const theme = Theme.get();
    themeButton.replaceChildren(icon(theme === 'light' ? 'sun' : theme === 'dark' ? 'moon' : 'auto'));
    themeButton.title = t('Theme: %s', {auto: t('auto'), light: t('light'), dark: t('dark')}[theme]);
    themeButton.setAttribute('aria-label', t('Theme: %s. Change theme', {auto: t('auto'), light: t('light'), dark: t('dark')}[theme]));
  }
  themeButton.addEventListener('click', function () {
    Theme.set({auto: 'light', light: 'dark', dark: 'auto'}[Theme.get()]);
  });
  window.addEventListener('themechange', showTheme);
  showTheme();

  // ------------------------------------------------- app and notifications

  // Phones only show notifications through the service worker.
  async function notify(title, text) {
    try {
      const reg = await navigator.serviceWorker.ready;
      await reg.showNotification(title, {body: text, tag: 'page', icon: '/icon-192.png'});
    } catch (err) {
      new Notification(title, {body: text});
    }
  }

  // Web Push: the browser's push address goes to the site, which uses it
  // when a mention or a private message comes and no page is open.
  async function subscribePush() {
    try {
      const reg = await navigator.serviceWorker.ready;
      const key = (await get('/api/push/key')).key;
      const raw = atob(key.replace(/-/g, '+').replace(/_/g, '/'));
      const bytes = Uint8Array.from(raw, function (c) { return c.charCodeAt(0); });
      const sub = await reg.pushManager.getSubscription() ||
        await reg.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: bytes});
      await post('/api/push', {endpoint: sub.endpoint});
      return true;
    } catch (err) {
      remember('push: ' + (err.message || err));
      return false;
    }
  }

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(function (err) {
    remember('service worker: ' + err.message);
  });

  // The browser says it can install the site as an app: offer it.
  let installOffer = null;
  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    installOffer = e;
    renderAccount();
  });

  // What this browser can do about notifications: on, off (not asked yet),
  // blocked, or none (no push in this browser).
  function notifyState() {
    if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) return 'none';
    return {granted: 'on', denied: 'blocked'}[Notification.permission] || 'off';
  }

  // A blocked site cannot ask again; only the browser's settings undo it.
  // The installed app has no address bar, but it shares the browser's.
  const BlockedHelp = matchMedia('(display-mode: standalone)').matches ?
    t('Notifications are blocked for this site, and the app cannot ask again. Open %s in the browser itself, tap the icon left of the address, Permissions, and allow Notifications (or reset them); the app uses the same setting. In Brave, also turn on "Use Google services for push messaging" under Settings, Privacy and security.', location.host) :
    t('Notifications are blocked for this site. Allow them in the browser\'s site settings (the icon left of the address, or Settings, Site settings, Notifications). In Brave, also turn on "Use Google services for push messaging" under Settings, Privacy and security.');

  async function turnOnNotifications() {
    const state = notifyState();
    if (state === 'none') { toast(t('This browser cannot show notifications from sites.'), 'bad'); return; }
    if (state === 'blocked') { toast(BlockedHelp, 'bad'); return; }
    if (await Notification.requestPermission() !== 'granted') toast(BlockedHelp, 'bad');
    else if (await subscribePush())
      toast(t('Notifications are on: mentions and private messages, when the chat is not in front of you.'));
    else toast(t('Notifications are allowed, but the browser would not sign up for push messages. In Brave, turn on "Use Google services for push messaging" under Settings, Privacy and security, then tap the bell again.'), 'bad');
    renderAccount();
    const bar = $('#notifybar');
    if (bar) bar.remove();
  }

  // The bell beside Sign out: always there, saying how things stand.
  function bellButton() {
    const state = notifyState();
    const bell = iconButton('bell', {on: t('Notifications are on'), off: t('Turn on notifications for mentions and private messages'),
      blocked: t('Notifications are blocked: click to see how to allow them'), none: t('This browser cannot show notifications')}[state],
      'bell-' + state);
    bell.addEventListener('click', function () {
      turnOnNotifications();   // when on, this checks the push sign-up again and says how it went
    });
    return bell;
  }

  // Once, after signing in: ask in plain sight rather than behind a menu,
  // or say plainly why notifications cannot be had here.
  function offerNotifications() {
    let asked = '';
    try { asked = localStorage.getItem('notify-asked-2') || ''; } catch (e) { }
    const state = notifyState();
    if (!Me.name || asked || state === 'on' || $('#notifybar')) return;
    const bar = el('div', 'notifybar');
    bar.id = 'notifybar';
    const no = el('button', 'small-link', state === 'off' ? t('Not now') : t('OK'));
    no.type = 'button';
    no.addEventListener('click', function () {
      try { localStorage.setItem('notify-asked-2', '1'); } catch (e) { }
      bar.remove();
    });
    bar.appendChild(icon('bell'));
    if (state === 'off') {
      const yes = el('button', 'primary', t('Turn on'));
      yes.type = 'button';
      yes.addEventListener('click', turnOnNotifications);
      bar.append(el('span', '', t('Get a notification when someone mentions you or sends you a private message?')), yes);
    } else if (state === 'blocked') bar.appendChild(el('span', '', BlockedHelp));
    else bar.appendChild(el('span', '', t('This browser cannot show notifications from sites, so mentions and private messages only show here.')));
    bar.appendChild(no);
    $('#main').prepend(bar);
  }

  // ---------------------------------------------------------------- account

  // The row at the bottom of the room list: who you are, a few buttons, and
  // a menu with the rest.
  function renderAccount() {
    const box = $('#account');
    box.replaceChildren();
    if (Me.name) {
      const who = link('/u/' + enc(Me.name), 'me');
      who.title = t('Your profile and settings');
      who.append(avatar(Me.name, Me.avatar, 'small'), el('span', '', Me.name));
      box.appendChild(who);
    } else {
      // Too narrow for a form: the sign-in page has all the ways in.
      box.appendChild(link('/signin', 'button signinbtn', t('Sign in or join')));
    }
    const tools = el('div', 'tools');
    const report = iconButton('bug', t('Report a problem'));
    report.addEventListener('click', openReport);
    tools.appendChild(report);
    if (installOffer) {
      const install = iconButton('install', t('Install the app'));
      install.addEventListener('click', async function () {
        installOffer.prompt();
        await installOffer.userChoice;
        installOffer = null;
        renderAccount();
      });
      tools.appendChild(install);
    }
    if (Me.name) tools.appendChild(bellButton());
    const more = iconButton('up', t('More'));
    more.addEventListener('click', function () { accountMenu(box); });
    tools.appendChild(more);
    box.appendChild(tools);
  }

  function accountMenu(box) {
    const open = $('.accountmenu');
    if (open) {
      open.remove();
      return;
    }
    const menu = el('nav', 'accountmenu');
    if (Me.name) menu.appendChild(link('/u/' + enc(Me.name), '', t('Your profile and settings')));
    for (const extra of Extras.accountLinks)
      menu.appendChild(link(extra.href, '', extra.title));
    if (['view-admin', 'manage-permissions', 'manage-settings', 'manage-channels', 'manage-private',
      'read-reports', 'manage-blocks', 'view-visitors', 'view-storage'].some(may) ||
      Extras.adminTabs.some(function (extra) { return extra.permission && may(extra.permission); }) ||
      Extras.adminScripts.some(function (extra) { return extra.permissions.some(may); }))
      menu.appendChild(link('/admin', '', t('Admin')));
    menu.append(link('/about', '', t('About this site')), link('/irc', '', t('Use your IRC client')));
    if (Me.name) {
      const out = link('#', '', t('Sign out'));
      out.addEventListener('click', async function (e) {
        e.preventDefault();
        await Keys.signOut();
        location.reload();
      });
      menu.appendChild(out);
    }
    box.appendChild(menu);
    // Any click closes it, a choice in it too.
    setTimeout(function () {
      document.addEventListener('click', function close(e) {
        if (menu.contains(e.target) && !e.target.closest('a')) return;
        menu.remove();
        document.removeEventListener('click', close);
      });
    });
  }

  function joinForm(caption) {
    const form = el('form', 'quickjoin');
    form.appendChild(el('span', 'caption', caption));
    const name = el('input');
    name.name = 'name';
    name.placeholder = t('Name');
    name.maxLength = 24;
    name.autocomplete = 'username';
    name.required = true;
    const pass = el('input');
    pass.name = 'password';
    pass.type = 'password';
    pass.placeholder = t('Password');
    pass.autocomplete = 'current-password';
    pass.required = true;
    const go = el('button', '', t('Join'));
    form.append(name, pass, go);
    if (body.dataset.sso) {
      const row = el('div', 'ssolink');
      row.appendChild(el('span', '', t('or sign in with')));
      for (const p of body.dataset.sso.split(',')) {
        const a = link('/signin-with/' + p, 'ssoicon');
        a.title = t('Sign in with %s', {github: 'GitHub', gitlab: 'GitLab', codeberg: 'Codeberg', google: 'Google',
          microsoft: 'Microsoft'}[p]);
        a.appendChild(el('span', 'ssologo ' + p));
        row.appendChild(a);
      }
      form.appendChild(row);
    }
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      go.disabled = true;
      go.textContent = t('One moment');
      if (await Keys.joinFrom(form, failed)) location.reload();
      go.disabled = false;
      go.textContent = t('Join');
    });
    return form;
  }

  // A small menu under a button: [caption, what it does] pairs.  Any click
  // closes it.
  function popMenu(anchor, items) {
    document.querySelectorAll('.popmenu').forEach(function (m) { m.remove(); });
    const menu = el('nav', 'popmenu');
    for (const item of items) {
      const b = el('button', '', item[0]);
      b.type = 'button';
      b.addEventListener('click', function () { menu.remove(); item[1](); });
      menu.appendChild(b);
    }
    const r = anchor.getBoundingClientRect();
    menu.style.left = Math.min(r.left, innerWidth - 220) + 'px';
    menu.style.top = (r.bottom + 4) + 'px';
    document.body.appendChild(menu);
    setTimeout(function () {
      document.addEventListener('click', function close(e) {
        if (menu.contains(e.target)) return;
        menu.remove();
        document.removeEventListener('click', close);
      });
    });
  }

  // ----------------------------------------------------------------- router

  function isAppPath(path) { return /^\/(p|m|u|dm)\/|^\/admin$/.test(path); }

  document.addEventListener('click', function (e) {
    const a = e.target.closest('a[href]');
    if (!a || a.target || e.ctrlKey || e.metaKey || e.shiftKey || a.origin !== location.origin) return;
    if (!isAppPath(a.pathname)) return;
    e.preventDefault();
    // A room picked from the phone's room list takes the place of the one
    // left, so Back leaves the chat once instead of room by room.
    const fromList = body.classList.contains('menu') && a.closest('#side');
    body.classList.remove('menu');
    route(a.pathname, fromList ? 'replace' : true);
  });

  // ------------------------------------------------------------ the back key

  // Back closes what is on top (the room list on a phone, the side panel, a
  // picture) before it leaves the place, the way Tally does it.  Opening one
  // adds a history entry, so Back has something to take away; closing one
  // some other way takes the entry back out.
  let layerEntry = false;
  let afterMove = null;   // runs instead of the next popstate's usual work
  // The width at which the room list slides over the chat (site.css).
  const Narrow = matchMedia('(max-width: 860px)');

  function onTop() {
    return body.classList.contains('menu') || !panel.hidden || !$('#lightbox').hidden;
  }

  function layerOpened() {
    if (layerEntry) return;
    layerEntry = true;
    history.pushState({}, '', location.pathname);
  }

  // Takes our entry back out once nothing is on top, then runs Then.
  function layerClosed(then) {
    if (!layerEntry || onTop()) {
      if (then) then();
      return;
    }
    layerEntry = false;
    afterMove = then || function () { };
    history.back();
  }

  // Closes the top one only: a picture over a thread leaves the thread.
  function closeTop() {
    if (!$('#lightbox').hidden) $('#lightbox').hidden = true;
    else if (body.classList.contains('menu')) body.classList.remove('menu');
    else if (!panel.hidden) {
      closePanel();
      if (location.pathname.startsWith('/m/') && S.room) history.replaceState({}, '', '/p/' + enc(S.room));
    }
  }

  function toggleMenu() {
    body.classList.toggle('menu');
    if (body.classList.contains('menu')) layerOpened();
    else layerClosed();
  }

  // On a phone, a tap beside the open room list closes it and does nothing
  // else.
  document.addEventListener('click', function (e) {
    if (!body.classList.contains('menu') || e.target.closest('#side, .menubtn')) return;
    e.preventDefault();
    e.stopPropagation();
    body.classList.remove('menu');
    layerClosed();
  }, true);

  // In the installed app, Back on the last page asks once before it closes
  // the app, as in Tally: a guard entry sits under the page.  Landing on it
  // shows a note and stays there, so the next Back finds nothing behind and
  // Android closes the app; a tap puts the page's entry back instead.  The
  // entries are made on a tap because Chrome's Back skips entries a page
  // adds before anyone has touched it.
  const Installed = matchMedia('(display-mode: standalone)').matches;
  let guarded = false;
  let here = location.pathname;   // the place shown, for the guard's entries
  document.addEventListener('pointerdown', function () {
    if (!Installed) return;
    if (!guarded) {
      guarded = true;
      history.replaceState({guard: true}, '', location.pathname);
      history.pushState({}, '', location.pathname);
    } else if (history.state && history.state.guard) history.pushState({}, '', here);
  }, true);

  window.addEventListener('popstate', function () {
    if (afterMove) {
      const then = afterMove;
      afterMove = null;
      then();
    } else if (history.state && history.state.guard) {
      history.replaceState({guard: true}, '', here);
      toast(t('Press back again to leave'));
    } else if (layerEntry) {
      layerEntry = false;
      closeTop();
      if (onTop()) layerOpened();
    } else route(location.pathname, false);
  });

  function clearView() {
    S.generation++;
    S.view = '';
    S.room = '';
    S.info = null;
    S.messages.clear();
    S.thread = 0;
    S.threadMessages.clear();
    S.dm = '';
    S.typers = {};
    clearTimeout(S.dmTimer);
    stream.replaceChildren();
    stream.className = '';
    stream.noPin = false;
    $('#roomhead').replaceChildren();
    $('#card').replaceChildren();
    $('#typing').replaceChildren();
    $('#composer-area').replaceChildren();
    closePanel();
  }

  // Alt+Up and Alt+Down walk the sidebar; Ctrl+K jumps to a room by name.
  document.addEventListener('keydown', function (e) {
    if (e.ctrlKey && e.key === 'k') {
      e.preventDefault();
      if (Narrow.matches) {
        body.classList.add('menu');
        layerOpened();
      }
      $('#jump').focus();
      return;
    }
    if (!e.altKey || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
    const rooms = Array.from(document.querySelectorAll('#roomlist a.room'));
    if (!rooms.length) return;
    e.preventDefault();
    let i = rooms.findIndex(function (a) { return a.classList.contains('active'); });
    i = (i + (e.key === 'ArrowDown' ? 1 : rooms.length - 1)) % rooms.length;
    route(rooms[i].getAttribute('href'), true);
  });

  function firstRoom() {
    const r = S.rooms.find(function (x) { return x.kind === 'channel'; });
    return r ? '/p/' + enc(r.slug) : '/';
  }

  // Push is true to add a history entry, 'replace' to take the current one's
  // place, false when Back or Forward already moved there.
  async function route(path, push) {
    if (path === '/') {
      path = firstRoom();
      if (path === '/') { location.href = '/'; return; }
    }
    // Leaving with something on top: its entry goes first.
    if (layerEntry && push) {
      layerEntry = false;
      return new Promise(function (done) {
        afterMove = function () { route(path, push).then(done); };
        history.back();
      });
    }
    if (push === 'replace') history.replaceState({}, '', path);
    else if (push) history.pushState({}, '', path);
    here = path;
    clearView();
    const parts = path.split('/').map(decodeURIComponent);
    try {
      if (parts[1] === 'u') await openProfile(parts[2]);
      else if (parts[1] === 'admin') await openAdmin();
      else for (const p of Parts) if (p.open && await p.open(parts)) break;
    } catch (err) {
      stream.appendChild(el('p', 'notice', err.message));
    }
    renderSide();
  }

  // The parts on this page, each with what it answers for (chat.js).
  const Parts = [];
  function renderSide() { for (const p of Parts) if (p.sidebar) p.sidebar(); }
  function syncNow(withRooms) { for (const p of Parts) if (p.sync) p.sync(withRooms); }

  // ------------------------------------------------------------------ panel

  function openPanel(title, cls) {
    // On a phone the room list slides over the chat, and the panel fills the
    // screen under it: a panel opened from the list closes the list.
    body.classList.remove('menu');
    panel.hidden = false;
    panel.className = cls || '';
    panel.replaceChildren();
    const head = el('header');
    head.appendChild(el('h2', '', title));
    const close = iconButton('close', t('Close'));
    close.addEventListener('click', function () {
      closePanel();
      if (location.pathname.startsWith('/m/') && S.room) history.replaceState({}, '', '/p/' + enc(S.room));
      layerClosed();
    });
    head.appendChild(close);
    panel.appendChild(head);
    body.classList.add('withpanel');
    layerOpened();
    return panel;
  }

  // Report a problem: what they write, and what the page knows.
  function openReport() {
    const box = openPanel(t('Report a problem'), 'report');
    const form = el('form', 'reportform');
    const text = el('textarea');
    text.rows = 8;
    text.maxLength = 4000;
    text.placeholder = t('What went wrong, or what looked wrong? What were you doing?');
    const send = el('button', 'primary', t('Send the report'));
    form.append(text, el('p', 'hint', t('Sent along: this page\'s address, your browser and screen size, and the last errors this page showed. Nothing else.')), send);
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      // The server mails the report before it answers, so say it is on its way.
      send.disabled = true;
      send.textContent = t('Sending…');
      text.disabled = true;
      const info = ['browser: ' + navigator.userAgent, 'screen: ' + innerWidth + 'x' + innerHeight + ' at ' + devicePixelRatio,
        'theme: ' + (document.documentElement.dataset.theme || 'auto'), 'signed in: ' + (Me.name || 'no'),
        'notifications: ' + notifyState() + (Installed ? ', installed app' : ', browser tab'),
        'last errors:'].concat(Trail.length ? Trail : ['none']).join('\n');
      try {
        toast(await post('/api/bug', {text: text.value, page: location.pathname, info: info}));
        closePanel();
        layerClosed();
      } catch (err) { failed(err); }
      send.disabled = false;
      send.textContent = t('Send the report');
      text.disabled = false;
    });
    box.appendChild(form);
    text.focus();
  }

  function closePanel() {
    panel.hidden = true;
    panel.replaceChildren();
    S.thread = 0;
    S.threadMessages.clear();
    body.classList.remove('withpanel');
  }

  // ---------------------------------------------------------------- profile

  async function openProfile(name) {
    const generation = S.generation;
    const who = await get('/api/user?name=' + enc(name));
    if (generation !== S.generation) return;
    S.title = who.name;
    const head = $('#roomhead');
    const menu = iconButton('menu', t('Channels'), 'menubtn');
    menu.addEventListener('click', toggleMenu);
    head.append(menu, el('div', 'titles'));
    $('.titles', head).appendChild(el('h1', '', who.name));

    const card = el('section', 'profile');
    const face = avatar(who.name, who.avatar, 'big');
    card.appendChild(face);
    const text = el('div', 'about');
    const line = el('h2', '', who.name);
    if (who.badge) line.appendChild(el('span', 'role', who.badge));
    if (who.banned) line.appendChild(el('span', 'role', t('banned')));
    text.appendChild(line);
    if (who.away) text.appendChild(el('p', 'away', t('Away: %s', who.away)));
    text.appendChild(el('p', 'seen', who.seen ? t('Joined %s · last here %s', dateText(who.joined), ago(who.seen)) :
      t('Joined %s', dateText(who.joined))));
    const bio = el('div', 'bio');
    bio.innerHTML = who.bio_html;   // safe html: rendered by the server, HTML escaped
    text.appendChild(bio);
    if (who.links) {
      const links = el('p', 'links');
      who.links.split(/\s+/).filter(function (l) { return /^https?:\/\//.test(l); }).forEach(function (l) {
        const a = link(l, '', l.replace(/^https?:\/\//, ''));
        a.rel = 'nofollow ugc me';
        a.target = '_blank';
        links.appendChild(a);
      });
      text.appendChild(links);
    }
    const tools = el('div', 'tools');
    for (const p of Parts) if (p.profileTools) p.profileTools(who, tools);
    if (Me.name === who.name) {
      const edit = el('button', '', t('Edit profile'));
      edit.type = 'button';
      edit.addEventListener('click', function () { editProfile(who, text); });
      tools.appendChild(edit);
      const pic = el('button', '', t('Change picture'));
      pic.type = 'button';
      const input = el('input');
      input.type = 'file';
      input.accept = 'image/*';
      input.hidden = true;
      pic.addEventListener('click', function () { input.click(); });
      input.addEventListener('change', async function () {
        const form = new FormData();
        form.append('avatar', '1');
        form.append('file', input.files[0]);
        try { await post('/api/upload', form); route(location.pathname, false); } catch (err) { failed(err); }
      });
      tools.append(pic, input);
    }
    text.appendChild(tools);
    card.appendChild(text);
    $('#card').appendChild(card);
    if (Me.name === who.name) $('#card').append(prefsBox(), signInsBox());
    if (Me.name === who.name && may('api-tokens')) $('#card').appendChild(tokensBox());

    for (const p of Parts) if (p.profile) await p.profile(who, generation);
  }

  // Mail about missed messages, and when to show as away; saved as soon as
  // they change.
  function prefsBox() {
    const box = el('section', 'prefs');
    const mail = el('label');
    const check = el('input');
    check.type = 'checkbox';
    check.checked = Me.mailNotes;
    mail.append(check, el('span', '', t('Email me about private messages and mentions I miss')));
    const hint = el('p', 'hint', Me.email ? tn(Me.mailHours, 'To %1:s, at most one every %0:d hours, and only when something new waits for you.',
      'To %1:s, at most one every %0:d hours, and only when something new waits for you.', Me.email) : t('Your account has no email address.'));
    check.disabled = !Me.email;
    const away = el('label');
    const after = el('select');
    [[0, t('never')], [5, tn(5, 'after %d minutes', 'after %d minutes')], [10, tn(10, 'after %d minutes', 'after %d minutes')], [15, tn(15, 'after %d minutes', 'after %d minutes')], [30, tn(30, 'after %d minutes', 'after %d minutes')],
      [60, t('after an hour')]].forEach(function (c) {
      const o = el('option', '', c[1]);
      o.value = c[0];
      after.appendChild(o);
    });
    after.value = Me.autoAway;
    away.append(el('span', '', t('Show me as away when I have not touched the chat')), after);
    // A failed save puts the box back as it was.
    check.addEventListener('change', async function () {
      try {
        await post('/api/prefs', {mail_notes: check.checked ? '1' : '0'});
        Me.mailNotes = check.checked;
        toast(t('Saved.'));
      } catch (err) { check.checked = Me.mailNotes; failed(err); }
    });
    after.addEventListener('change', async function () {
      try {
        await post('/api/prefs', {auto_away: after.value});
        Me.autoAway = Number(after.value);
        toast(t('Saved.'));
      } catch (err) { after.value = Me.autoAway; failed(err); }
    });
    box.append(mail, hint, away);
    return box;
  }

  // Auto away: no key, click or tap for Me.autoAway minutes in any tab shows
  // the member as away ("idle") until they are back.  The tabs share the
  // time and the flag; the server leaves an away typed with /away alone.
  function shared(key, value) {
    try {
      if (value === undefined) return localStorage.getItem(key) || '';
      localStorage.setItem(key, value);
    } catch (e) { }
    return '';
  }
  let lastTouch = Date.now();
  ['keydown', 'pointerdown', 'wheel'].forEach(function (kind) {
    document.addEventListener(kind, function () {
      if (Date.now() - lastTouch < 10000) return;
      lastTouch = Date.now();
      shared('touched', String(lastTouch));
      if (Me.name && shared('idle') === '1') {
        shared('idle', '0');
        post('/api/prefs', {idle: '0'}).catch(function () { });
      }
    }, {capture: true, passive: true});
  });
  setInterval(function () {
    const touched = Math.max(lastTouch, Number(shared('touched')) || 0);
    if (Me.name && Me.autoAway > 0 && shared('idle') !== '1' && Date.now() - touched >= Me.autoAway * 60000) {
      shared('idle', '1');
      post('/api/prefs', {idle: '1'}).catch(function () { });
    }
  }, 30000);

  // Sign-ins at GitHub, GitLab and the others linked to this account.
  function signInsBox() {
    const box = el('details', 'tokens');
    box.hidden = true;
    box.appendChild(el('summary', '', t('Sign in with GitHub, GitLab and others')));
    const list = el('div', 'tokenlist');
    box.appendChild(list);
    const show = async function () {
      const logins = await get('/api/logins');
      box.hidden = !logins.providers.length;
      list.replaceChildren();
      for (const p of logins.providers) {
        const row = el('div', 'person');
        row.appendChild(el('b', '', p.title));
        if (p.login) {
          row.appendChild(el('span', 'dim', t('linked as %s', p.login)));
          const x = el('button', 'small-link', t('Unlink'));
          x.type = 'button';
          x.addEventListener('click', async function () {
            try { await post('/api/logins', {unlink: p.name}); show(); } catch (err) { failed(err); }
          });
          row.appendChild(x);
        } else {
          row.appendChild(link('/signin-with/' + p.name, 'small-link', t('Link')));
        }
        list.appendChild(row);
      }
    };
    show().catch(failed);
    return box;
  }

  // Tokens let a bot or a script act as this member (Authorization: Bearer).
  function tokensBox() {
    const box = el('details', 'tokens');
    box.appendChild(el('summary', '', t('Tokens for bots and scripts')));
    const list = el('div', 'tokenlist');
    const show = async function () {
      const tokens = await get('/api/tokens');
      list.replaceChildren();
      if (!tokens.length) list.appendChild(el('p', 'dim', t('None yet. Apps you signed in to show here too.')));
      for (const t of tokens) {
        const row = el('div', 'person');
        row.append(el('b', '', t.name || t.kind), el('span', 'dim', window.t('%s, made %s', t.kind, ago(t.created))));
        const x = el('button', 'small-link', window.t('Take back'));
        x.type = 'button';
        x.addEventListener('click', async function () {
          try { await post('/api/tokens', {delete: t.id}); show(); } catch (err) { failed(err); }
        });
        row.appendChild(x);
        list.appendChild(row);
      }
    };
    box.addEventListener('toggle', function () { if (box.open) show().catch(failed); });
    const form = el('form', 'invite');
    const name = el('input');
    name.placeholder = t('What will use it, such as my-bot');
    const make = el('button', 'primary', t('Make a token'));
    form.append(name, make);
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      try {
        const made = JSON.parse(await post('/api/tokens', {name: name.value}));
        const shown = el('pre', 'newtoken', made.token);
        form.after(shown);
        form.after(el('p', 'hint', t('Copy it now; it is not shown again. Send it as Authorization: Bearer followed by the token. Anyone holding it can talk as you, so keep it secret.')));
        name.value = '';
        show();
      } catch (err) { failed(err); }
    });
    box.append(list, form);
    return box;
  }

  function editProfile(who, box) {
    const form = el('form', 'editprofile');
    const bio = el('textarea');
    bio.value = who.bio;
    bio.placeholder = t('A few words about you. Markdown works.');
    const links = el('input');
    links.value = who.links;
    links.placeholder = t('Links, separated by spaces');
    const save = el('button', 'primary', t('Save'));
    form.append(bio, links, save);
    box.appendChild(form);
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      try { await post('/api/profile', {bio: bio.value, links: links.value}); route(location.pathname, false); } catch (err) { failed(err); }
    });
  }

  // ------------------------------------------------------------------ admin

  const ScriptVersion = document.currentScript ? new URLSearchParams(document.currentScript.src.split('?')[1]).get('v') : null;
  const Scripts = new Map();
  function loadScript(src) {
    if (!Scripts.has(src)) {
      Scripts.set(src, new Promise(function (resolve, reject) {
        const script = el('script');
        script.src = src + (ScriptVersion === null ? '' : '?v=' + enc(ScriptVersion));
        script.onload = resolve;
        script.onerror = function () {
          Scripts.delete(src);
          script.remove();
          reject(new Error(t('Could not load %s.', src)));
        };
        document.head.appendChild(script);
      }));
    }
    return Scripts.get(src);
  }

  async function openAdmin() {
    const generation = S.generation;
    if (document.readyState === 'loading')
      await new Promise(function (resolve) { document.addEventListener('DOMContentLoaded', resolve, {once: true}); });
    if (generation !== S.generation) return;
    try { await loadScript('/static/admin.js'); } catch (err) { failed(err); return; }
    if (generation !== S.generation) return;
    await window.Chat.openAdmin();
  }

  // tabs inside a tab: a row of smaller ones, the one last chosen remembered
  function subTabs(box, id, list) {
    const nav = el('nav', 'subtabs');
    nav.setAttribute('role', 'tablist');
    box.appendChild(nav);
    const parts = {};
    let current = '';
    try { current = localStorage.getItem('sub-' + id) || ''; } catch (e) { }
    const select = function (key) {
      if (!parts[key]) key = list[0].key;
      for (const k in parts) {
        parts[k].button.classList.toggle('on', k === key);
        parts[k].button.setAttribute('aria-selected', k === key ? 'true' : 'false');
        parts[k].holder.hidden = k !== key;
      }
      current = key;
      try { localStorage.setItem('sub-' + id, key); } catch (e) { }
      // on a phone the row scrolls: the chosen one in sight
      const b = parts[key].button;
      if (b.scrollIntoView && nav.scrollWidth > nav.clientWidth) b.scrollIntoView({block: 'nearest', inline: 'nearest'});
    };
    for (const s of list) {
      const b = el('button', '', s.title);
      b.type = 'button';
      b.setAttribute('role', 'tab');
      const badge = el('span', 'sub-count');
      badge.hidden = true;
      b.appendChild(badge);
      const holder = el('div', 'subpart');
      holder.setAttribute('role', 'tabpanel');
      holder.hidden = true;
      b.addEventListener('click', function () { select(s.key); });
      nav.appendChild(b);
      box.appendChild(holder);
      parts[s.key] = {button: b, holder: holder, badge: badge};
    }
    select(current);
    return {
      holder: function (key) { return parts[key].holder; },
      select: select,
      count: function (key, n) { const b = parts[key].badge; b.hidden = !(n > 0); b.textContent = n > 0 ? n.toLocaleString(locale) : ''; }
    };
  }

  // a part of a page whose words are on their way: a turning mark and what it waits for
  function waiting(holder, words) {
    const p = el('p', 'lv-wait');
    p.append(el('span', 'lv-spinner'), ' ' + (words || t('Loading…')));
    holder.replaceChildren(p);
    return p;
  }

  // facts about one thing, as label and value lines in a picked row's box
  function facts(holder, pairs) {
    const dl = el('dl', 'lv-facts');
    for (const p of pairs) {
      if (p[1] === '' || p[1] === null || p[1] === undefined) continue;
      dl.appendChild(el('dt', '', p[0]));
      const dd = el('dd');
      if (typeof p[1] === 'object') dd.appendChild(p[1]); else dd.textContent = String(p[1]);
      dl.appendChild(dd);
    }
    holder.appendChild(dl);
    return dl;
  }
  function chip(text, cls) { return el('span', 'lv-chip' + (cls ? ' ' + cls : ''), text); }

  // ------------------------------------------------------------------ start

  function ready(then) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { then(); }, {once: true});
    else then();
  }

  async function start() {
    if (Me.name) {
      try {
        const me = await get('/api/me');
        Me.avatar = me.avatar;
        Me.can = me.can;
        Me.away = me.away;
        Me.ignores = me.ignores;
        Me.wrapped = me.wrapped;
        Me.verified = me.verified;
        Me.email = me.email;
        Me.mailNotes = me.mail_notes;
        Me.autoAway = me.auto_away;
        Me.mailHours = me.mail_hours;
        Me.password = me.password;
      } catch (err) { }
    }
    for (const p of Parts) if (p.prepare) await p.prepare();
    renderAccount();
    renderSide();
    for (const p of Parts) if (p.start) p.start();
    const thread = Number(body.dataset.thread);
    const view = body.dataset.view;
    const target = body.dataset.target;
    try {
      if (view === 'profile') await openProfile(target);
      else if (view === 'admin') await openAdmin();
      else for (const p of Parts) if (p.view && await p.view(view, target, thread)) break;
    } catch (err) {
      stream.appendChild(el('p', 'notice', err.message));
    }
    syncNow(true);
  }

  // What another script, loaded after this one, can
  // add: sidebar groups ({title, test, sigil, button, always}), things over
  // a room's messages, badges by a name, rooms for # completion and
  // /commands the page runs itself.
  const Extras = {groups: [], cards: [], badges: [], rooms: [], commands: {}, adminTabs: [], adminScripts: [], accountLinks: [], places: {}};
  window.Chat = {extras: Extras, me: Me, state: S, icons: Icons, el: el, link: link, icon: icon, get: get,
    post: post, enc: enc, toast: toast, failed: failed, route: route, openPanel: openPanel, ago: ago,
    subTabs: subTabs, facts: facts, chip: chip, waiting: waiting, $: $, stream: stream, Site: Site,
    iconButton: iconButton, sizeText: sizeText, syncNow: syncNow, toggleMenu: toggleMenu,
    locale: locale, clock: clock, shared: shared, loadScript: loadScript, parts: Parts, body: body,
    panel: panel, Reactions: Reactions, avatar: avatar, dayLabel: dayLabel, keepPinned: keepPinned,
    nearBottom: nearBottom, may: may, mayHere: mayHere, notify: notify, popMenu: popMenu,
    joinForm: joinForm, layerOpened: layerOpened, layerClosed: layerClosed,
    offerNotifications: offerNotifications, subscribePush: subscribePush};

  // after the page's other scripts (chat.js, extensions) have added themselves
  ready(start);
})();
