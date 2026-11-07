(function() {
  // The server stamps the per-session token onto this script tag when it serves the page.
  const TOKEN = document.currentScript?.dataset.brainstormToken;
  if (!TOKEN) throw new Error('brainstorm helper: server token missing from script tag');
  const WS_URL = 'ws://' + window.location.host + '/?token=' + encodeURIComponent(TOKEN);
  let ws = null;
  let eventQueue = [];

  const IDLE_HINT = 'Click an option above, then return to the terminal';
  const NO_CHOICES_HINT = 'Nothing to select on this screen. Continue in the terminal';
  // Elements that already handle Enter/Space and focus natively.
  const NATIVE_CONTROLS = 'a[href], button, input, select, textarea, summary';

  // Mirror the socket state in the frame header. Full-document screens have no
  // header, so a missing element is not an error.
  function setStatus(state, text) {
    const status = document.querySelector('.header .status');
    if (!status || status.dataset.state === state) return;
    status.dataset.state = state;
    status.textContent = text;
  }

  function connect() {
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
      setStatus('connected', 'Connected');
      eventQueue.forEach(e => ws.send(JSON.stringify(e)));
      eventQueue = [];
    };

    ws.onmessage = (msg) => {
      const data = JSON.parse(msg.data);
      if (data.type === 'reload') {
        window.location.reload();
      }
    };

    ws.onclose = () => {
      setStatus('disconnected', 'Disconnected, retrying…');
      setTimeout(connect, 1000);
    };
  }

  function sendEvent(event) {
    event.timestamp = Date.now();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(event));
    } else {
      eventQueue.push(event);
    }
  }

  // Capture clicks on choice elements
  document.addEventListener('click', (e) => {
    const target = e.target.closest('[data-choice]');
    if (!target) return;

    sendEvent({
      type: 'click',
      text: target.textContent.trim(),
      choice: target.dataset.choice,
      id: target.id || null
    });

    // Update indicator bar (defer so toggleSelect runs first)
    setTimeout(() => {
      const indicator = document.getElementById('indicator-text');
      if (!indicator) return;
      const container = target.closest('.options') || target.closest('.cards');
      const selected = container ? container.querySelectorAll('.selected') : [];
      if (selected.length === 0) {
        indicator.textContent = IDLE_HINT;
        return;
      }
      const summary = selected.length === 1
        ? (selected[0].querySelector('h3, .content h3, .card-body h3')?.textContent?.trim() || selected[0].dataset.choice) + ' selected'
        : selected.length + ' selected';
      // Build nodes rather than innerHTML so labels containing < or & render as text.
      const highlight = document.createElement('span');
      highlight.className = 'selected-text';
      highlight.textContent = summary;
      indicator.replaceChildren(highlight, ' — return to terminal to continue');
    }, 0);
  });

  // Choices are usually <div onclick>. Enter and Space activate a focused choice
  // through the same click path a mouse uses.
  document.addEventListener('keydown', (e) => {
    if ((e.key !== 'Enter' && e.key !== ' ') || e.repeat) return;
    const target = e.target.closest('[data-choice]');
    if (!target || target !== e.target || target.matches(NATIVE_CONTROLS)) return;
    e.preventDefault(); // Space would otherwise scroll the page.
    target.click();
  });

  function syncPressed(items) {
    items.forEach(o => o.setAttribute('aria-pressed', String(o.classList.contains('selected'))));
  }

  // Give choices button semantics so keyboard and screen-reader users can reach
  // them, and replace the click hint when the screen has nothing to click.
  function enhanceChoices() {
    const choices = document.querySelectorAll('[data-choice]');
    choices.forEach(el => {
      if (el.matches(NATIVE_CONTROLS)) return;
      if (!el.hasAttribute('tabindex')) el.tabIndex = 0;
      if (!el.hasAttribute('role')) el.setAttribute('role', 'button');
    });
    syncPressed(document.querySelectorAll('.options [data-choice], .cards [data-choice]'));
    const indicator = document.getElementById('indicator-text');
    if (indicator && choices.length === 0) indicator.textContent = NO_CHOICES_HINT;
  }

  // Frame UI: selection tracking
  window.selectedChoice = null;

  window.toggleSelect = function(el) {
    const container = el.closest('.options') || el.closest('.cards');
    const multi = container && container.dataset.multiselect !== undefined;
    if (container && !multi) {
      container.querySelectorAll('.option, .card').forEach(o => o.classList.remove('selected'));
    }
    if (multi) {
      el.classList.toggle('selected');
    } else {
      el.classList.add('selected');
    }
    syncPressed(container ? container.querySelectorAll('[data-choice]') : [el]);
    window.selectedChoice = el.dataset.choice;
  };

  // Expose API for explicit use
  window.brainstorm = {
    send: sendEvent,
    choice: (value, metadata = {}) => sendEvent({ type: 'choice', value, ...metadata })
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', enhanceChoices);
  } else {
    enhanceChoices();
  }
  connect();
})();
