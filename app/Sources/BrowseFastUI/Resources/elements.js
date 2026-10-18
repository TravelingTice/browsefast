// Injected into every page. window.__browsefast.snapshot() returns a JSON string describing the
// interactive elements currently visible, numbered for the agent. The numbered elements are kept in
// window.__browsefast.elements so later actions can target them by id.
(() => {
  if (window.__browsefast) return;

  const INTERACTIVE = [
    'a[href]', 'button', 'input:not([type="hidden"])', 'select', 'textarea', 'summary',
    '[role="button"]', '[role="link"]', '[role="checkbox"]', '[role="radio"]', '[role="switch"]',
    '[role="tab"]', '[role="menuitem"]', '[role="menuitemcheckbox"]', '[role="menuitemradio"]',
    '[role="option"]', '[role="combobox"]', '[role="textbox"]', '[role="searchbox"]', '[role="slider"]',
    '[role="spinbutton"]', '[role="treeitem"]',
    '[contenteditable=""]', '[contenteditable="true"]', '[tabindex]:not([tabindex="-1"])', '[onclick]',
  ].join(',');

  const TEXT_INPUTS = new Set(['text', 'email', 'search', 'tel', 'url', 'password', 'number', '']);

  const clean = (s, max = 80) => {
    const t = (s || '').replace(/\s+/g, ' ').trim();
    return t.length > max ? t.slice(0, max - 1) + '…' : t;
  };

  // Apps (React etc.) often make plain divs clickable with no markup hint except a pointer cursor.
  // The cursor is inherited, so only the outermost element of a pointer area counts.
  function startsPointerArea(el) {
    if (getComputedStyle(el).cursor !== 'pointer') return false;
    const parent = el.parentElement;
    return !parent || getComputedStyle(parent).cursor !== 'pointer';
  }

  function collect(root, out) {
    const seen = new Set();
    root.querySelectorAll(INTERACTIVE).forEach(el => { seen.add(el); out.push(el); });
    root.querySelectorAll('*').forEach(el => {
      if (!seen.has(el) && startsPointerArea(el)) out.push(el);
      if (el.shadowRoot) collect(el.shadowRoot, out);
    });
    return out;
  }

  function role(el) {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit.split(' ')[0];
    const tag = el.tagName.toLowerCase();
    if (tag === 'a') return 'link';
    if (tag === 'button' || tag === 'summary') return 'button';
    if (tag === 'select') return el.multiple ? 'listbox' : 'combobox';
    if (tag === 'textarea' || el.isContentEditable) return 'textbox';
    if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (type === 'search') return 'searchbox';
      if (TEXT_INPUTS.has(type)) return 'textbox';
      if (type === 'checkbox' || type === 'radio') return type;
      if (type === 'range') return 'slider';
      if (['submit', 'button', 'reset', 'image'].includes(type)) return 'button';
      return type; // date, time, color, file, …
    }
    return 'button'; // tabindex/onclick elements behave like buttons
  }

  // A bare "27" or "+" says little; nearby markup often has the real meaning (a calendar's data-date, a title).
  function context(el) {
    let node = el;
    for (let i = 0; i < 4 && node; i++, node = node.parentElement) {
      for (const attr of ['data-date', 'datetime', 'aria-label', 'title']) {
        const v = node.getAttribute && node.getAttribute(attr);
        if (v && clean(v) !== clean(el.innerText)) return clean(v.replace(/ \d\d:\d\d:\d\d.*$/, ''), 40);
      }
    }
    return '';
  }

  function label(el) {
    const own = ownLabel(el);
    if (own.length > 3) return own;
    const extra = context(el);
    return extra ? (own ? `${own} (${extra})` : extra) : own;
  }

  function ownLabel(el) {
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const t = by.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ');
      if (clean(t)) return clean(t);
    }
    const aria = el.getAttribute('aria-label');
    if (clean(aria)) return clean(aria);
    if (el.labels && el.labels.length) {
      const t = Array.from(el.labels).map(l => l.innerText).join(' ');
      if (clean(t)) return clean(t);
    }
    if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type) && el.value) return clean(el.value);
    const text = clean(el.innerText);
    if (text) return text;
    for (const attr of ['placeholder', 'title', 'alt', 'name']) {
      const v = el.getAttribute(attr);
      if (clean(v)) return clean(v);
    }
    const img = el.querySelector('img[alt], svg[aria-label], [aria-label]');
    if (img) return clean(img.getAttribute('alt') || img.getAttribute('aria-label'));
    return '';
  }

  function value(el) {
    if (el.tagName === 'INPUT') {
      const type = (el.type || '').toLowerCase();
      if (type === 'password') return el.value ? '(filled, hidden)' : '';
      if (type === 'checkbox' || type === 'radio' || ['submit', 'button', 'reset'].includes(type)) return null;
      return clean(el.value, 120);
    }
    if (el.tagName === 'TEXTAREA') return clean(el.value, 120);
    if (el.tagName === 'SELECT') return clean(Array.from(el.selectedOptions).map(o => o.text).join(', '));
    if (el.isContentEditable) return clean(el.innerText, 120);
    const ariaValue = el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow');
    return ariaValue ? clean(ariaValue) : null;
  }

  function states(el) {
    const s = [];
    if (el.disabled || el.closest('[aria-disabled="true"], .is-disabled, .disabled')) s.push('disabled');
    if (el.tagName === 'A' && !clean(el.innerText) && el.querySelector('img, svg')) s.push('image');
    if (el.checked || el.getAttribute('aria-checked') === 'true') s.push('checked');
    if (el.getAttribute('aria-selected') === 'true') s.push('selected');
    const expanded = el.getAttribute('aria-expanded');
    if (expanded) s.push(expanded === 'true' ? 'expanded' : 'collapsed');
    if (el.required || el.getAttribute('aria-required') === 'true') s.push('required');
    if (el.readOnly) s.push('readonly');
    if (document.activeElement === el) s.push('focused');
    // Wizards and tab strips mark the current step with a class rather than ARIA.
    const marked = node => node && typeof node.className === 'string' && /(^|[\s-])(is-)?(active|current|selected)(\s|$)/.test(node.className);
    if (el.getAttribute('aria-current') || marked(el) || marked(el.parentElement)) s.push('current');
    return s;
  }

  function isShown(el, rect) {
    if (rect.width < 2 || rect.height < 2) return false;
    if (el.closest('[aria-hidden="true"], [inert]')) return false;
    const style = getComputedStyle(el);
    return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0.05;
  }

  // Covered by something else (a modal, a cookie banner)? Probe the middle of the visible part.
  function isOnTop(el, rect) {
    const x = Math.min(Math.max(rect.left + rect.width / 2, 1), innerWidth - 1);
    const y = Math.min(Math.max(rect.top + rect.height / 2, 1), innerHeight - 1);
    let hit = document.elementFromPoint(x, y);
    while (hit && hit.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return !!hit && (hit === el || el.contains(hit) || hit.contains(el));
  }

  // The text currently on screen, top to bottom, so the agent can tell when what it's looking for is visible.
  function visibleText(max = 1500) {
    const out = [];
    let total = 0, last = '';
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT,
      { acceptNode: n => n.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT });
    while (walker.nextNode() && total < max) {
      const el = walker.currentNode.parentElement;
      if (!el || ['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(el.tagName)) continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.bottom <= 0 || r.top >= innerHeight) continue;
      const style = getComputedStyle(el);
      if (style.visibility === 'hidden' || style.display === 'none') continue;
      const t = clean(walker.currentNode.nodeValue, 200);
      if (t && t !== last) { out.push(t); total += t.length + 1; last = t; }
    }
    return out.join('\n').slice(0, max);
  }

  // all: include elements above and below the viewport too (used on search results, where the right result
  // is often further down). Off-screen elements can't be checked for overlap, so that check is skipped for them.
  function snapshot(opts = {}) {
    const started = performance.now();
    const candidates = collect(document, []);
    const accepted = new Set();
    const elements = [];
    let above = 0, below = 0;

    for (const el of candidates) {
      if (accepted.has(el)) continue;
      const rect = el.getBoundingClientRect();
      if (!isShown(el, rect)) continue;
      const offscreen = rect.bottom <= 0 || rect.top >= innerHeight;
      if (offscreen && !opts.all) { if (rect.bottom <= 0) above++; else below++; continue; }
      if (rect.right <= 0 || rect.left >= innerWidth) continue;
      if (!offscreen && !isOnTop(el, rect)) continue;

      // Skip a control nested in an accepted one that covers the same area (e.g. <a><button>).
      let parent = el.parentElement, duplicate = false;
      while (parent) {
        if (accepted.has(parent)) {
          const p = parent.getBoundingClientRect();
          duplicate = rect.width * rect.height > 0.8 * p.width * p.height;
          break;
        }
        parent = parent.parentElement;
      }
      if (duplicate) continue;

      accepted.add(el);
      const entry = {
        id: elements.length + 1,
        role: role(el),
        label: label(el),
        rect: [Math.round(rect.left), Math.round(rect.top), Math.round(rect.width), Math.round(rect.height)],
      };
      const v = value(el);
      if (v !== null) entry.value = v;
      const s = states(el);
      if (s.length) entry.states = s;
      if (el.tagName === 'INPUT' && !['text', 'checkbox', 'radio', 'submit', 'button'].includes(el.type)) entry.inputType = el.type;
      if (el.tagName === 'A' && el.href) {
        try {
          let u = new URL(el.href);
          // Google wraps results in /url?q=… and /imgres?imgrefurl=…; show where the link really leads.
          const target = u.searchParams.get('imgrefurl') || u.searchParams.get('url') || u.searchParams.get('q');
          if (/^(\/url|\/imgres)/.test(u.pathname) && target && /^https?:/.test(target)) {
            entry.via = u.pathname === '/imgres' ? 'image preview of' : 'redirect to';
            u = new URL(target);
          }
          // Long query strings are mostly tracking ids; they cost tokens without helping the decision.
          const query = u.search.length <= 40 ? u.search : (u.search ? '?…' : '');
          entry.href = (u.host === location.host ? '' : u.host) + u.pathname + query;
        } catch {}
      }
      if (el.tagName === 'SELECT') entry.options = Array.from(el.options).slice(0, 12).map(o => clean(o.text, 40));
      elements.push(entry);
    }

    window.__browsefast.elements = Array.from(accepted);
    const scrollMax = Math.max(0, document.documentElement.scrollHeight - innerHeight);
    return JSON.stringify({
      url: location.href,
      title: document.title,
      viewport: [innerWidth, innerHeight],
      scroll: [Math.round(scrollY), Math.round(scrollMax)],
      elements,
      text: visibleText(),
      offscreenAbove: above,
      offscreenBelow: below,
      ms: Math.round(performance.now() - started),
    });
  }

  // Safety: BrowseFast is read-only for now, so it never commits a booking, purchase or personal details.
  const COMMIT = /\b(confirm\w*|bevestig\w*|pay|payment|betaal\w*|checkout|check out|afreken\w*|place order|bestel\w*|buy|kopen|koop|purchase|book now|boek nu|reserveer nu|subscribe|abonneer\w*)\b/i;
  const personalForm = form => !!form && !!form.querySelector(
    'input[type="password"], input[type="email"], input[type="tel"], [autocomplete^="cc-"]');

  function blockedReason(el) {
    const text = clean(el.innerText || el.value || el.getAttribute('aria-label') || '');
    if (COMMIT.test(text)) return `"${text}" looks like it books, buys or confirms something`;
    const isSubmit = (el.tagName === 'BUTTON' && (el.getAttribute('type') || 'submit') === 'submit')
      || (el.tagName === 'INPUT' && el.type === 'submit');
    if (isSubmit && personalForm(el.form)) return 'this form asks for personal details';
    return null;
  }

  function setValue(el, text) {
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.focus();
    if (el.isContentEditable) {
      document.execCommand('selectAll');
      document.execCommand('insertText', false, text);
      return;
    }
    // Use the native setter so frameworks like React notice the change.
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function pressEnter(el) {
    const form = el.form || el.closest('form');
    if (personalForm(form)) return 'this form asks for personal details';
    el.focus();
    const init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
    const notHandled = el.dispatchEvent(new KeyboardEvent('keydown', init));
    el.dispatchEvent(new KeyboardEvent('keypress', init));
    el.dispatchEvent(new KeyboardEvent('keyup', init));
    if (notHandled && form) form.requestSubmit ? form.requestSubmit() : form.submit();
    return null;
  }

  // cmd: { kind: 'click' | 'type' | 'submit' | 'scroll' | 'back', id?, text?, direction? }
  function act(cmd) {
    const done = (extra = {}) => JSON.stringify({ ok: true, ...extra });
    const fail = (error, extra = {}) => JSON.stringify({ ok: false, error, ...extra });
    const el = cmd.id ? window.__browsefast.elements[cmd.id - 1] : null;
    if (cmd.id && (!el || !el.isConnected)) return fail('That element is no longer on the page');

    switch (cmd.kind) {
      case 'click': {
        const blocked = blockedReason(el);
        if (blocked) return fail(blocked, { blocked: true });
        el.scrollIntoView({ block: 'center', inline: 'center' });
        if (el.focus) el.focus({ preventScroll: true });
        el.click();
        return done();
      }
      case 'type':
        setValue(el, cmd.text || '');
        return done();
      case 'submit': {
        const blocked = pressEnter(el);
        return blocked ? fail(blocked, { blocked: true }) : done();
      }
      case 'scroll':
        window.scrollBy({ top: (cmd.direction === 'up' ? -0.8 : 0.8) * innerHeight });
        return done();
      case 'back':
        history.back();
        return done();
    }
    return fail(`Unknown action ${cmd.kind}`);
  }

  const pageText = () => (document.body ? document.body.innerText : '')
    .replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim().slice(0, 12000);

  // Resolves once the DOM hasn't changed for quietMs (or after maxMs), plus a beat for CSS transitions.
  function waitForQuiet(quietMs = 350, maxMs = 3000) {
    return new Promise(resolve => {
      let timer;
      const finish = () => { observer.disconnect(); clearTimeout(cap); setTimeout(resolve, 250); };
      const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(finish, quietMs); });
      observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      timer = setTimeout(finish, quietMs);
      const cap = setTimeout(finish, maxMs);
    });
  }

  // Closes a cookie consent banner, preferring the privacy-friendly button. Returns the button text, or null.
  const COOKIE_REJECT = /^(only necessary|necessary only|use necessary cookies only|reject all|reject|decline|weigeren|alles weigeren|alleen noodzakelijke?( cookies)?|noodzakelijke cookies)$/i;
  const COOKIE_ACCEPT = /^(accept all|accept|allow all|agree|i agree|ok|got it|alles accepteren|accepteren|akkoord|toestaan|alle cookies accepteren)$/i;
  function dismissCookies() {
    const buttons = Array.from(document.querySelectorAll('button, [role="button"], a, input[type="button"], input[type="submit"]'));
    for (const pattern of [COOKIE_REJECT, COOKIE_ACCEPT]) {
      for (const b of buttons) {
        const text = clean(b.innerText || b.value || b.getAttribute('aria-label'), 60);
        if (!pattern.test(text)) continue;
        const rect = b.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) continue;
        let box = b.parentElement, isConsent = false;
        for (let i = 0; i < 5 && box && box !== document.body; i++, box = box.parentElement) {
          const hint = `${box.id} ${box.className} ${box.getAttribute('aria-label') || ''} ${(box.innerText || '').slice(0, 500)}`;
          if (/cookie|consent|gdpr/i.test(hint)) { isConsent = true; break; }
        }
        if (isConsent) { b.click(); return text; }
      }
    }
    return null;
  }

  window.__browsefast = { snapshot, act, pageText, waitForQuiet, dismissCookies, elements: [] };
})();
