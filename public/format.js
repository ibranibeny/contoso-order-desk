const statuses = new Map([
  ['Payment pending', 'pending'],
  ['Packed', 'packed'],
  ['Shipped', 'shipped'],
  ['Out for delivery', 'out'],
  ['Delivered', 'delivered'],
  ['Cancelled', 'cancelled']
]);

export function isValidOrderId(value) {
  return typeof value === 'string' && /^ORD-[0-9]{6}$/.test(value);
}

export function formatStatus(value) {
  const badge = statuses.get(value);
  return badge ? { label: value, badge } : { label: 'Status unavailable', badge: '' };
}

export function formatDate(value, includeTime = false) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}(?:T.*)?$/.test(value)) {
    return 'Not available';
  }
  const day = new Date(`${value.slice(0, 10)}T00:00:00Z`);
  const date = new Date(value);
  if (Number.isNaN(day.getTime()) || Number.isNaN(date.getTime()) ||
      day.toISOString().slice(0, 10) !== value.slice(0, 10)) {
    return 'Not available';
  }
  return new Intl.DateTimeFormat('en-GB', {
    timeZone: 'UTC',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    ...(includeTime ? { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' } : {})
  }).format(date);
}
