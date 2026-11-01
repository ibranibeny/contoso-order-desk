import { formatDate, formatStatus, isValidOrderId } from './format.js';

const formatMessage = 'Order numbers look like ORD-123456.';
const failureMessage = 'Unable to look up the order. Please try again.';

export function initLookup(document, request = fetch) {
  const form = document.getElementById('lookup-form');
  const input = document.getElementById('order-number');
  const button = document.getElementById('lookup-button');
  const message = document.getElementById('lookup-message');
  const results = document.getElementById('order-results');
  const fields = ['result-id', 'result-status', 'result-delivery', 'result-updated']
    .map((id) => document.getElementById(id));
  let latestLookup = 0;

  function showMessage(text, kind = 'info') {
    message.textContent = text;
    message.className = `od-alert od-alert--${kind}`;
    message.hidden = false;
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const lookup = ++latestLookup;
    const orderId = input.value;
    results.hidden = true;
    fields.forEach((field) => { field.textContent = ''; });
    message.hidden = true;
    message.textContent = '';
    button.textContent = 'Look up order';
    input.setAttribute('aria-invalid', 'false');

    if (!isValidOrderId(orderId)) {
      input.setAttribute('aria-invalid', 'true');
      showMessage(formatMessage, 'warn');
      return;
    }

    button.textContent = 'Looking up…';
    showMessage('Looking up order…');
    try {
      const response = await request(`/api/orders/${encodeURIComponent(orderId)}`, {
        signal: AbortSignal.timeout(10000)
      });
      if (lookup !== latestLookup) return;
      if (response.status === 404) {
        showMessage('Order not found', 'warn');
        return;
      }
      if (response.status === 400) {
        input.setAttribute('aria-invalid', 'true');
        showMessage(formatMessage, 'warn');
        return;
      }
      if (!response.ok) throw new Error('Lookup failed');
      const order = await response.json();
      if (lookup !== latestLookup) return;
      if (!order || order.id !== orderId || typeof order.status !== 'string' ||
          typeof order.lastUpdated !== 'string' ||
          !(typeof order.estimatedDelivery === 'string' || order.estimatedDelivery === null)) {
        throw new Error('Invalid order response');
      }
      const status = formatStatus(order.status);
      fields[0].textContent = order.id;
      fields[1].textContent = status.label;
      fields[1].className = status.badge ? `od-badge od-badge--${status.badge}` : 'od-badge';
      fields[2].textContent = formatDate(order.estimatedDelivery);
      fields[3].textContent = formatDate(order.lastUpdated, true);
      message.hidden = true;
      message.textContent = '';
      results.hidden = false;
    } catch {
      if (lookup === latestLookup) showMessage(failureMessage, 'danger');
    } finally {
      if (lookup === latestLookup) button.textContent = 'Look up order';
    }
  });
}

if (typeof document !== 'undefined') initLookup(document);
