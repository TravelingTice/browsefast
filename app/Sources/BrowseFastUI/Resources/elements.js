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

  function collect(root, out) {
    root.querySelectorAll(INTERACTIVE).forEach(el => out.push(el));
    root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) collect(el.shadowRoot, out); });
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

  function label(el) {
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
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') s.push('disabled');
    if (el.checked || el.getAttribute('aria-checked') === 'true') s.push('checked');
    if (el.getAttribute('aria-selected') === 'true') s.push('selected');
    const expanded = el.getAttribute('aria-expanded');
    if (expanded) s.push(expanded === 'true' ? 'expanded' : 'collapsed');
    if (el.required || el.getAttribute('aria-required') === 'true') s.push('required');
    if (el.readOnly) s.push('readonly');
    if (document.activeElement === el) s.push('focused');
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

  function snapshot() {
    const started = performance.now();
    const candidates = collect(document, []);
    const accepted = new Set();
    const elements = [];
    let above = 0, below = 0;

    for (const el of candidates) {
      if (accepted.has(el)) continue;
      const rect = el.getBoundingClientRect();
      if (!isShown(el, rect)) continue;
      if (rect.bottom <= 0) { above++; continue; }
      if (rect.top >= innerHeight) { below++; continue; }
      if (rect.right <= 0 || rect.left >= innerWidth) continue;
      if (!isOnTop(el, rect)) continue;

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
          const u = new URL(el.href);
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
      offscreenAbove: above,
      offscreenBelow: below,
      ms: Math.round(performance.now() - started),
    });
  }

  window.__browsefast = { snapshot, elements: [] };
})();
