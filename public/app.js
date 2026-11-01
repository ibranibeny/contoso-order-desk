import {
  ORDER_ID_HINT,
  normalizeOrderId,
  isValidOrderId,
  trackerSteps,
  badgeVariant,
  formatDateTime,
  timeZoneLabel,
  deliverySummary
} from './format.js';

const form = document.querySelector('#lookup-form');
const input = document.querySelector('#order-id');
const button = document.querySelector('#lookup-button');
const result = document.querySelector('#result');
const chips = document.querySelector('#chips');

const RECENT_KEY = 'orderDesk.recentLookups';
const EXAMPLES = ['ORD-100232', 'ORD-100231', 'ORD-100233'];
let inFlight;

const ICONS = {
  check: ['M5 12.5 10 17 19 7.5'],
  copy: ['M9 9h10v10H9z', 'M5 15V5h10'],
  shield: ['M12 3 5 6v5c0 4.5 3 8.5 7 10 4-1.5 7-5.5 7-10V6z', 'm9 12 2 2 4-4'],
  warn: ['M12 4 2.8 19.5h18.4z', 'M12 10v4.5', 'M12 17.2v.1'],
  search: ['M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13z', 'm20 20-4.8-4.8'],
  cloud: ['M7 18h10a4 4 0 0 0 .5-8 6 6 0 0 0-11.5 1.5A3.3 3.3 0 0 0 7 18z', 'M4 4l16 16'],
  cancel: ['M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z', 'm9 9 6 6m0-6-6 6']
};

function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  for (const d of ICONS[name]) {
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', d);
    svg.append(path);
  }
  return svg;
}

// Every value from the API goes through textContent, never innerHTML.
function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

function show(node) {
  result.replaceChildren(node);
}

function renderLoading() {
  const card = el('div', 'od-card result-card');
  card.setAttribute('aria-label', 'Looking up the order');
  const head = el('div', 'result-card__head');
  head.append(el('div', 'od-skeleton skeleton-line skeleton-line--title'), el('div', 'od-skeleton skeleton-pill'));
  const facts = el('div', 'od-facts');
  facts.append(el('div', 'od-skeleton skeleton-block'), el('div', 'od-skeleton skeleton-block'));
  card.append(head, facts, el('div', 'od-skeleton skeleton-line'));
  show(card);
}

function renderAlert(kind, iconName, title, text) {
  const alert = el('div', `od-alert od-alert--${kind}`);
  alert.setAttribute('role', kind === 'danger' ? 'alert' : 'status');
  const badge = el('div', 'od-alert__icon');
  badge.append(icon(iconName));
  alert.append(badge, el('p', 'od-alert__title', title), el('p', 'od-alert__text', text));
  show(alert);
}

function fact(label, value, note, hero = false) {
  const box = el('div', hero ? 'od-fact od-fact--hero' : 'od-fact');
  box.append(el('span', 'od-fact__label', label), el('span', 'od-fact__value', value));
  if (note) box.append(el('span', 'od-fact__meta', note));
  return box;
}

function tracker(status) {
  const steps = trackerSteps(status);
  const list = el('ol', 'od-tracker');
  list.setAttribute('aria-label', 'Delivery progress');
  list.style.setProperty('--od-steps', String(steps.length));
  for (const step of steps) {
    const item = el('li', step.state === 'done' ? 'is-done' : step.state === 'current' ? 'is-current' : '');
    const dot = el('span', 'od-tracker__dot');
    if (step.state === 'done') dot.append(icon('check'));
    item.append(dot, el('span', '', step.label));
    if (step.state === 'current') {
      item.setAttribute('aria-current', 'step');
      item.append(el('span', 'od-visually-hidden', ' (current step)'));
    } else if (step.state === 'done') {
      item.append(el('span', 'od-visually-hidden', ' (done)'));
    }
    list.append(item);
  }
  return list;
}

function copyButton(orderId) {
  const btn = el('button', 'od-icon-btn');
  btn.type = 'button';
  btn.title = 'Copy order number';
  btn.setAttribute('aria-label', `Copy order number ${orderId}`);
  btn.append(icon('copy'));
  btn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(orderId);
      btn.title = 'Copied';
      btn.classList.add('is-copied');
      setTimeout(() => btn.classList.remove('is-copied'), 1500);
    } catch {
      btn.title = 'Copy is not available in this browser';
    }
  });
  return btn;
}

function renderOrder(order) {
  const card = el('article', 'od-card result-card');
  card.setAttribute('aria-label', `Order ${order.id}`);

  const head = el('header', 'result-card__head');
  const who = el('div', 'result-card__who');
  const idRow = el('div', 'result-card__id');
  idRow.append(el('span', 'result-card__number', order.id), copyButton(order.id));
  who.append(el('span', 'od-fact__label', 'Order'), idRow);
  const badge = el('span', `od-badge od-badge--${badgeVariant(order.status)}`);
  badge.append(el('span', 'od-badge__dot'), document.createTextNode(order.status || 'Unknown status'));
  head.append(who, badge);

  const delivery = deliverySummary(order);
  const facts = el('div', 'od-facts');
  const updated = formatDateTime(order.lastUpdated);
  facts.append(
    fact(delivery.label, delivery.value, delivery.note, true),
    fact('Last updated', updated || 'Not available', updated ? `Your time (${timeZoneLabel(order.lastUpdated)})` : '')
  );

  card.append(head, facts);
  if (order.status === 'Cancelled') {
    const note = el('div', 'od-alert od-alert--danger result-card__cancelled');
    const badgeIcon = el('div', 'od-alert__icon');
    badgeIcon.append(icon('cancel'));
    note.append(badgeIcon, el('p', 'od-alert__title', 'This order was cancelled'), el('p', 'od-alert__text', 'It will not be delivered. Any refund is handled by the payments team.'));
    card.append(note);
  } else if (trackerSteps(order.status).length) {
    card.append(tracker(order.status));
  }

  const privacy = el('p', 'result-card__privacy');
  privacy.append(icon('shield'), document.createTextNode('Payment and contact details are not shown in Order Desk.'));
  card.append(privacy);
  show(card);
}

function readRecent() {
  try {
    const list = JSON.parse(localStorage.getItem(RECENT_KEY) || '[]');
    return Array.isArray(list) ? list.filter(isValidOrderId).slice(0, 5) : [];
  } catch {
    return [];
  }
}

function remember(orderId) {
  const list = [orderId, ...readRecent().filter((id) => id !== orderId)].slice(0, 5);
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify(list));
  } catch {
    // Storage can be blocked; recent lookups are a convenience only.
  }
  renderChips();
}

function renderChips() {
  const recent = readRecent();
  const ids = recent.length ? recent : EXAMPLES;
  const label = el('span', 'lookup-chips__label', recent.length ? 'Recent' : 'Try');
  const buttons = ids.map((id) => {
    const chip = el('button', 'od-chip', id);
    chip.type = 'button';
    chip.addEventListener('click', () => lookUp(id));
    return chip;
  });
  chips.replaceChildren(label, ...buttons);
}

function setBusy(busy) {
  button.disabled = busy;
  button.textContent = busy ? 'Looking up…' : 'Look up';
  result.setAttribute('aria-busy', String(busy));
}

function updateAddress(orderId) {
  const url = new URL(window.location.href);
  url.searchParams.set('order', orderId);
  window.history.replaceState(null, '', url);
}

async function lookUp(raw) {
  const orderId = normalizeOrderId(raw);
  input.value = orderId;
  if (!isValidOrderId(orderId)) {
    renderAlert('warn', 'warn', 'Check the order number', `${ORDER_ID_HINT}. You can also type just the six digits.`);
    input.focus();
    return;
  }
  updateAddress(orderId);
  inFlight?.abort();
  const controller = new AbortController();
  inFlight = controller;
  setBusy(true);
  renderLoading();
  try {
    const res = await fetch(`/api/orders/${encodeURIComponent(orderId)}`, {
      headers: { Accept: 'application/json' },
      signal: controller.signal
    });
    const body = await res.json().catch(() => null);
    if (res.ok && body && body.id) {
      renderOrder(body);
      remember(orderId);
    } else if (res.status === 404 && body && body.error) {
      renderAlert('info', 'search', `We couldn't find ${orderId}`, 'Check the number with the customer and try again.');
    } else if (res.status === 400 && body && body.error) {
      renderAlert('warn', 'warn', 'Check the order number', body.error);
    } else {
      renderAlert('danger', 'cloud', 'Order lookup is unavailable', 'Please try again in a moment.');
    }
  } catch (error) {
    if (error.name !== 'AbortError') {
      renderAlert('danger', 'cloud', 'Order lookup is unavailable', 'Check your connection and try again.');
    }
  } finally {
    if (inFlight === controller) setBusy(false);
  }
}

form.addEventListener('submit', (event) => {
  event.preventDefault();
  lookUp(input.value);
});

// Press "/" anywhere to jump to the order number field.
document.addEventListener('keydown', (event) => {
  const typing = event.target instanceof HTMLElement && event.target.closest('input, textarea, [contenteditable="true"]');
  if (event.key === '/' && !typing && !event.ctrlKey && !event.metaKey && !event.altKey) {
    event.preventDefault();
    input.focus();
    input.select();
  }
});

renderChips();
const linked = new URLSearchParams(window.location.search).get('order');
if (linked) lookUp(linked);
