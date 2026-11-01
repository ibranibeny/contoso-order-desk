import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { app } from '../src/app.js';

let server;
let baseUrl;

before(async () => {
  server = app.listen(0);
  if (!server.listening) await once(server, 'listening');
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => {
  server.close();
});

test('GET /api/orders/:orderId returns the status and estimated delivery of a known order', async () => {
  const res = await fetch(`${baseUrl}/api/orders/ORD-100232`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.id, 'ORD-100232');
  assert.equal(body.status, 'Out for delivery');
  assert.match(body.estimatedDelivery, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(body.lastUpdated, /^\d{4}-\d{2}-\d{2}T/);
});

test('the response never includes customer contact or payment details', async () => {
  const res = await fetch(`${baseUrl}/api/orders/ORD-100231`);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), ['estimatedDelivery', 'id', 'lastUpdated', 'status']);
});

test('an order without a delivery estimate returns null for estimatedDelivery', async () => {
  const res = await fetch(`${baseUrl}/api/orders/ORD-100234`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, 'Payment pending');
  assert.equal(body.estimatedDelivery, null);
});

test('a malformed order number returns 400 with a helpful message', async () => {
  const res = await fetch(`${baseUrl}/api/orders/12345`);
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: 'Order numbers look like ORD-123456' });
});

test('an unknown order number returns 404', async () => {
  const res = await fetch(`${baseUrl}/api/orders/ORD-999999`);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'Order not found' });
});
