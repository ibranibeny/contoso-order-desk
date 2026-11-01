// Pure helpers for the Order Desk page. They never touch the DOM, so node --test can cover them.

export const ORDER_ID_PATTERN = /^ORD-\d{6}$/;
export const ORDER_ID_HINT = 'Order numbers look like ORD-123456';

export const STEPS = ['Order placed', 'Payment confirmed', 'Packed', 'Shipped', 'Out for delivery', 'Delivered'];

const STEP_FOR_STATUS = {
  'Payment pending': 1,
  Packed: 2,
  Shipped: 3,
  'Out for delivery': 4,
  Delivered: 5
};

const BADGE_FOR_STATUS = {
  'Payment pending': 'pending',
  Packed: 'packed',
  Shipped: 'shipped',
  'Out for delivery': 'out',
  Delivered: 'delivered',
  Cancelled: 'cancelled'
};

const DAY_MS = 24 * 60 * 60 * 1000;

// Accepts what agents tend to type: lower case, spaces, the digits only, or ORD without the dash.
export function normalizeOrderId(input) {
  const value = String(input ?? '').trim().toUpperCase().replace(/\s+/g, '');
  if (/^\d{6}$/.test(value)) return `ORD-${value}`;
  if (/^ORD\d{6}$/.test(value)) return `ORD-${value.slice(3)}`;
  return value;
}

export function isValidOrderId(value) {
  return typeof value === 'string' && ORDER_ID_PATTERN.test(value);
}

// Index into STEPS of the step the order is at, or -1 when the tracker does not apply (cancelled or unknown).
export function stepIndex(status) {
  return STEP_FOR_STATUS[status] ?? -1;
}

// The delivery tracker as a list of { label, state } where state is 'done', 'current' or 'todo'.
// Empty when the tracker does not apply (cancelled or unknown status).
export function trackerSteps(status) {
  const current = stepIndex(status);
  if (current < 0) return [];
  return STEPS.map((label, index) => {
    let state = index < current ? 'done' : index === current ? 'current' : 'todo';
    if (status === 'Delivered' && index === current) state = 'done';
    const text = state === 'current' && status === 'Payment pending' ? 'Awaiting payment' : label;
    return { label: text, state };
  });
}

export function badgeVariant(status) {
  return BADGE_FOR_STATUS[status] ?? 'neutral';
}

function parseDay(isoDate) {
  if (typeof isoDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(isoDate)) return null;
  const date = new Date(`${isoDate}T00:00:00Z`);
  return Number.isNaN(date.getTime()) ? null : date;
}

function parseInstant(isoDateTime) {
  if (typeof isoDateTime !== 'string') return null;
  const date = new Date(isoDateTime);
  return Number.isNaN(date.getTime()) ? null : date;
}

// "2026-11-05" -> "5 Nov 2026". Delivery dates are calendar dates, so they are formatted in UTC to avoid shifting a day.
export function formatDate(isoDate) {
  const date = parseDay(isoDate);
  if (!date) return '';
  return new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(date);
}

// "2026-11-03T06:40:00Z" -> "3 Nov 2026, 13:40" in the agent's time zone (or the one passed in).
export function formatDateTime(isoDateTime, { timeZone } = {}) {
  const date = parseInstant(isoDateTime);
  if (!date) return '';
  return new Intl.DateTimeFormat('en-GB', {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone
  }).format(date);
}

// Short name of the time zone used by formatDateTime, for example "GMT+7" or "UTC".
export function timeZoneLabel(isoDateTime, { timeZone } = {}) {
  const date = parseInstant(isoDateTime);
  if (!date) return '';
  const part = new Intl.DateTimeFormat('en-GB', { timeZoneName: 'short', timeZone })
    .formatToParts(date)
    .find((p) => p.type === 'timeZoneName');
  return part ? part.value : '';
}

// Today's calendar date in the agent's local time, as YYYY-MM-DD.
export function localIsoDate(now = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

// "Today", "Tomorrow", "In 3 days", "2 days ago"... only within two weeks, otherwise an empty string.
export function relativeDay(isoDate, today = localIsoDate()) {
  const target = parseDay(isoDate);
  const base = parseDay(today);
  if (!target || !base) return '';
  const days = Math.round((target - base) / DAY_MS);
  if (days === 0) return 'Today';
  if (days === 1) return 'Tomorrow';
  if (days === -1) return 'Yesterday';
  if (days > 1 && days <= 14) return `In ${days} days`;
  if (days < -1 && days >= -14) return `${-days} days ago`;
  return '';
}

// What the delivery panel shows for an order: a label, a main value and a short note.
export function deliverySummary(order, today = localIsoDate()) {
  const status = order?.status;
  const eta = order?.estimatedDelivery;
  if (status === 'Cancelled') {
    return { label: 'Estimated delivery', value: 'No delivery', note: 'This order was cancelled' };
  }
  if (status === 'Delivered' && parseDay(eta)) {
    return { label: 'Delivered', value: formatDate(eta), note: relativeDay(eta, today) };
  }
  if (!parseDay(eta)) {
    return {
      label: 'Estimated delivery',
      value: 'Not scheduled yet',
      note: status === 'Payment pending' ? 'Scheduled once payment is confirmed' : ''
    };
  }
  return { label: 'Estimated delivery', value: formatDate(eta), note: relativeDay(eta, today) };
}
