// Forms on the server-rendered forum pages.
(function () {
  'use strict';

  async function post(path, fields) {
    const response = await fetch(path, {method: 'POST', body: fields, credentials: 'same-origin'});
    if (!response.ok) throw new Error(await response.text() || t('Could not save the forum.'));
    return response.json();
  }

  function topicAddress(id, page, postId) {
    const path = '/forum/t/' + Number(id);
    return path + (page > 1 ? '?page=' + Number(page) : '') + (postId ? '#post-' + Number(postId) : '');
  }

  function codeButtons(box) {
    box.querySelectorAll('.code').forEach(function (block) {
      const copy = block.querySelector('.copy');
      if (copy) {
        copy.dataset.forumCode = '1';
        copy.textContent = t('Copy');
        copy.addEventListener('click', async function () {
          try {
            await navigator.clipboard.writeText(block.querySelector('pre code').textContent);
            copy.textContent = t('Copied');
          } catch (err) { alert(t('Could not copy the code.')); }
        });
      }
      const flip = block.querySelector('.flip');
      if (flip) {
        flip.dataset.forumCode = '1';
        flip.textContent = t('Source');
        flip.addEventListener('click', function () {
          flip.textContent = block.classList.toggle('source') ? t('Document') : t('Source');
        });
      }
    });
  }

  // The post box gets the shared editor (editor.js): its toolbar, and the
  // post as it will look from the forum's own renderer.
  function editor(textarea) {
    if (!window.Editor) return;
    const form = textarea.closest('form');
    const files = fileRules(textarea);
    window.Editor.attach(textarea, {
      compact: true,
      mode: 'write',
      storeKey: 'forum-edit-mode',
      viewClass: 'forum-body body',
      emptyWords: t('The post shows here as you write.'),
      preview: async function (text, signal) {
        const fields = new URLSearchParams(new FormData(form));
        fields.set('body', text);
        const response = await fetch('/api/forum/preview', {method: 'POST', body: fields, credentials: 'same-origin', signal: signal});
        if (!response.ok) throw new Error(await response.text());
        return (await response.json()).html;
      },
      afterPreview: codeButtons,
      hint: files ? t('Markdown. Drag, paste or') : undefined,
      linkTools: files ? function (editor) {
        editor.tool(t('Add a file'), '', editor.svg('<path d="M20 11.5l-8.2 8.2a5 5 0 0 1-7-7l8.5-8.6a3.4 3.4 0 0 1 4.8 4.8l-8.4 8.5a1.7 1.7 0 0 1-2.4-2.4l7.7-7.8"/>'), editor.choose);
      } : undefined,
      pictures: files
    });
  }

  // Files in a post: the page says the largest size and the kinds the
  // admin accepts; the forum keeps the file and the post names it.
  function fileRules(textarea) {
    const kinds = (textarea.dataset.uploadTypes || '').split(' ').filter(Boolean);
    const most = Number(textarea.dataset.uploadMb || 0);
    if (!kinds.length || !most) return null;
    return {
      accept: kinds.map(function (k) { return '.' + k; }).join(','),
      label: t('add files'),
      refuses: function (file) {
        const kind = (/\.([A-Za-z0-9]+)$/.exec(file.name || '') || ['', ''])[1].toLowerCase();
        // a pasted screenshot has no name of its own; it is a picture
        if (!kind && /^image\/(png|jpeg|gif|webp)$/.test(file.type)) return '';
        if (kinds.indexOf(kind) < 0) return t('%s is not a kind of file accepted here.', file.name || '');
        if (file.size > most * 1024 * 1024) return t('%s is too big: files can be %d MB at most here.', file.name || '', most);
        return '';
      },
      send: async function (file, name) {
        const body = new FormData();
        body.append('file', file, name);
        const response = await fetch('/api/forum/upload', {method: 'POST', body: body, credentials: 'same-origin'});
        if (!response.ok) throw new Error((await response.text()).trim().slice(0, 200) || t('The file could not be uploaded.'));
        const answer = await response.json();
        const words = answer.name.replace(/[\[\]]/g, '');
        // a blank or a parenthesis in the name would end the link early
        const address = answer.url.replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');
        return {put: (answer.image ? '!' : '') + '[' + words + '](' + address + ')', words: t('%s is uploaded.', answer.name)};
      }
    };
  }

  document.querySelectorAll('form[data-forum-form]').forEach(function (form) {
    form.addEventListener('submit', async function (event) {
      event.preventDefault();
      if (form.dataset.busy) return;
      const path = form.getAttribute('action');
      if (path === '/api/forum/post/delete' && !confirm(t('Delete this post?'))) return;
      const fields = new URLSearchParams(new FormData(form));
      const error = form.querySelector('.forum-error');
      const buttons = form.querySelectorAll('button');
      error.textContent = '';
      form.dataset.busy = '1';
      buttons.forEach(function (button) { button.disabled = true; });
      try {
        const data = await post(path, fields);
        if (data.topic_id) location.assign(topicAddress(data.topic_id, data.page || 1, data.post_id));
        else if (data.topic_deleted) location.assign('/forum');
        else location.reload();
      } catch (err) {
        error.textContent = err.message;
        // the text is still unsaved: the editor goes on warning before the page is left
        form.querySelectorAll('textarea').forEach(function (box) { if (box.editor && box.editor.notSaved) box.editor.notSaved(); });
      }
      finally {
        delete form.dataset.busy;
        buttons.forEach(function (button) { button.disabled = false; });
      }
    });
  });
  function quoteMarkdown(author, topic, postId, body) {
    // Names are literal Markdown, including brackets and formatting characters.
    const name = author.replace(/([\\`*_[\]<>])/g, '\\$1');
    return '> **' + name + '** ' + t('wrote') + ' ([' + t('post') + '](/forum/t/' + Number(topic) + '?post=' + Number(postId) + '#post-' + Number(postId) + ')):\n' +
      body.replace(/\r\n?/g, '\n').split('\n').map(function (line) { return '> ' + line; }).join('\n') + '\n\n';
  }

  document.querySelectorAll('.forum-quote').forEach(function (button) {
    button.addEventListener('click', function () {
      const reply = document.querySelector('#quick-reply');
      if (!reply) return;
      const textarea = reply.querySelector('.forum-editor');
      textarea.value += (textarea.value ? '\n\n' : '') + quoteMarkdown(button.dataset.author, button.dataset.topic, button.dataset.post, button.dataset.body);
      // the editor hears of the new text as it would of typing
      textarea.dispatchEvent(new Event('input', {bubbles: true}));
      textarea.focus(); reply.scrollIntoView({block: 'start'});
    });
  });
  document.querySelectorAll('[data-forum-new]').forEach(function (anchor) {
    anchor.addEventListener('click', function () { document.querySelector('#new-topic').open = true; });
  });
  document.querySelectorAll('[data-forum-panel]').forEach(function (button) {
    button.addEventListener('click', function () {
      const panel = document.getElementById(button.dataset.forumPanel);
      const opening = panel.hidden;
      const post = button.closest('.forum-post-content');
      post.querySelectorAll('.forum-action-panel').forEach(function (other) { other.hidden = true; });
      post.querySelectorAll('[data-forum-panel]').forEach(function (other) { other.setAttribute('aria-expanded', 'false'); });
      panel.hidden = !opening;
      button.setAttribute('aria-expanded', String(opening));
      if (opening) {
        const field = panel.querySelector('textarea, input:not([type=hidden]), button');
        if (field) field.focus();
      }
    });
  });
  document.querySelectorAll('.forum-editor').forEach(editor);
  codeButtons(document);
  document.querySelectorAll('[data-forum-tools]').forEach(function (tools) { tools.hidden = false; });
  document.querySelectorAll('.signout').forEach(function (anchor) {
    anchor.addEventListener('click', async function (event) {
      event.preventDefault();
      try { await Keys.signOut(); location.reload(); }
      catch (err) { alert(err.message); }
    });
  });
})();
