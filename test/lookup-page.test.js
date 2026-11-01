import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initLookup } from '../public/app.js';

const order = {
  id: 'ORD-123456',
  status: 'Shipped',
  lastUpdated: '2026-11-03T10:15:00Z',
  estimatedDelivery: '2026-11-05'
};

function setup(request) {
  const elements = new Map();
  let submit;
  const document = {
    getElementById(id) {
      if (!elements.has(id)) {
        elements.set(id, {
          textContent: '',
          hidden: true,
          value: '',
          attributes: {},
          setAttribute(name, value) { this.attributes[name] = value; },
          addEventListener(type, listener) {
            assert.equal(type, 'submit');
            submit = listener;
          }
        });
      }
      return elements.get(id);
    }
  };
  initLookup(document, request);
  return {
    get: (id) => elements.get(id),
    async submit(value = order.id) {
      elements.get('order-number').value = value;
      let prevented = false;
      const pending = submit({ preventDefault() { prevented = true; } });
      assert.equal(prevented, true);
      await pending;
    }
  };
}

function response(status = 200, body = order) {
  return { status, ok: status === 200, async json() { return body; } };
}

function assertCleared(page) {
  assert.equal(page.get('order-results').hidden, true);
  for (const id of ['result-id', 'result-status', 'result-delivery', 'result-updated']) {
    assert.equal(page.get(id).textContent, '');
  }
}

test('lookup requests the contracted API and renders only allowed fields', async () => {
  const page = setup(async (url, options) => {
    assert.equal(url, '/api/orders/ORD-123456');
    assert.ok(options.signal instanceof AbortSignal);
    return response(200, {
      ...order,
      customer: { email: 'hidden@example.com', phone: '555-0100' },
      payment: { last4: '1234' }
    });
  });
  await page.submit();
  assert.equal(page.get('order-results').hidden, false);
  assert.equal(page.get('result-id').textContent, order.id);
  assert.equal(page.get('result-status').textContent, 'Shipped');
  assert.equal(page.get('result-status').className, 'od-badge od-badge--shipped');
  assert.equal(page.get('result-delivery').textContent, '5 Nov 2026');
  assert.equal(page.get('result-updated').textContent, '3 Nov 2026, 10:15');
  assert.equal(page.get('lookup-message').hidden, true);
});

test('invalid and empty input clear previous results without requesting the API', async () => {
  let requests = 0;
  const page = setup(async () => { requests++; return response(); });
  for (const value of ['', '12345', 'ORD-123456\n', '<img src=x onerror=alert(1)>']) {
    await page.submit();
    await page.submit(value);
    assertCleared(page);
    assert.equal(page.get('lookup-message').textContent, 'Order numbers look like ORD-123456.');
    assert.equal(page.get('order-number').attributes['aria-invalid'], 'true');
  }
  assert.equal(requests, 4);
});

test('404 and 400 show clear messages and remove the previous order', async () => {
  for (const [status, message] of [
    [404, 'Order not found'], [400, 'Order numbers look like ORD-123456.']
  ]) {
    let next = response();
    const page = setup(async () => next);
    await page.submit();
    next = response(status, { error: '<img src=x onerror=alert(1)>' });
    await page.submit('ORD-999999');
    assertCleared(page);
    assert.equal(page.get('lookup-message').textContent, message);
    assert.equal(page.get('lookup-button').textContent, 'Look up order');
  }
});

test('service, network, timeout and malformed-response failures clear results and allow retry', async () => {
  for (const failure of [
    async () => response(500),
    async () => { throw new TypeError('Network failure'); },
    async () => { throw new DOMException('Timed out', 'TimeoutError'); },
    async () => ({ ...response(), async json() { throw new SyntaxError('Invalid JSON'); } }),
    async () => response(200, null),
    async () => response(200, { ...order, id: 'ORD-999999' }),
    async () => response(200, { id: order.id })
  ]) {
    let request = async () => response();
    const page = setup((...args) => request(...args));
    await page.submit();
    request = failure;
    await page.submit();
    assertCleared(page);
    assert.equal(page.get('lookup-message').textContent, 'Unable to look up the order. Please try again.');
    assert.equal(page.get('lookup-button').textContent, 'Look up order');
    request = async () => response();
    await page.submit();
    assert.equal(page.get('order-results').hidden, false);
    assert.equal(page.get('order-number').attributes['aria-invalid'], 'false');
  }
});

test('loading clears stale results immediately and an older response cannot overwrite a newer lookup', async () => {
  let resolve;
  let next = Promise.resolve(response());
  const page = setup(() => next);
  await page.submit();
  next = new Promise((done) => { resolve = done; });
  const older = page.submit();
  assertCleared(page);
  assert.equal(page.get('lookup-message').textContent, 'Looking up order…');
  next = Promise.resolve(response(404));
  await page.submit('ORD-999999');
  resolve(response());
  await older;
  assertCleared(page);
  assert.equal(page.get('lookup-message').textContent, 'Order not found');
});

test('a newer invalid submission supersedes an in-flight lookup, including JSON parsing', async () => {
  let resolve;
  const body = new Promise((done) => { resolve = done; });
  const page = setup(async () => ({ ...response(), json: () => body }));
  const older = page.submit();
  await Promise.resolve();
  await page.submit('');
  resolve(order);
  await older;
  assertCleared(page);
  assert.equal(page.get('lookup-message').textContent, 'Order numbers look like ORD-123456.');
});

test('unavailable dates and untrusted statuses never render HTML or extra response fields', async () => {
  const page = setup(async () => response(200, {
    ...order, status: '<img src=x onerror=alert(1)>', estimatedDelivery: null
  }));
  await page.submit();
  assert.equal(page.get('result-status').textContent, 'Status unavailable');
  assert.equal(page.get('result-status').className, 'od-badge');
  assert.equal(page.get('result-delivery').textContent, 'Not available');
});
