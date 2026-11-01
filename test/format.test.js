import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { formatDate, formatStatus, isValidOrderId } from '../public/format.js';

test('order IDs require ORD- followed by exactly six digits', () => {
  for (const value of ['ORD-000000', 'ORD-123456', 'ORD-999999']) {
    assert.equal(isValidOrderId(value), true);
  }
  for (const value of ['', '123456', 'ord-123456', ' ORD-123456', 'ORD-123456 ',
    'ORD-12345', 'ORD-1234567', 'ORD-１２３４５６', 'ORD-123456\n', null, 123456]) {
    assert.equal(isValidOrderId(value), false);
  }
});

test('status labels use only known design-system badges', () => {
  for (const [label, badge] of [
    ['Payment pending', 'pending'], ['Packed', 'packed'], ['Shipped', 'shipped'],
    ['Out for delivery', 'out'], ['Delivered', 'delivered'], ['Cancelled', 'cancelled']
  ]) {
    assert.deepEqual(formatStatus(label), { label, badge });
  }
  for (const value of ['<script>alert(1)</script>', '__proto__', 'Unknown', null]) {
    assert.deepEqual(formatStatus(value), { label: 'Status unavailable', badge: '' });
  }
});

test('every status in the synthetic order source has a display label and badge', () => {
  const orders = JSON.parse(readFileSync(new URL('../data/orders.json', import.meta.url), 'utf8'));
  for (const status of new Set(orders.map((order) => order.status))) {
    const formatted = formatStatus(status);
    assert.equal(formatted.label, status);
    assert.ok(formatted.badge);
  }
});

test('dates and timestamps have predictable UTC formatting', () => {
  assert.equal(formatDate('2026-11-05'), '5 Nov 2026');
  assert.equal(formatDate('2026-11-05T18:59:00Z', true), '5 Nov 2026, 18:59');
  assert.equal(formatDate('2026-11-05T23:30:00-05:00', true), '6 Nov 2026, 04:30');
  assert.equal(formatDate('2024-02-29'), '29 Feb 2024');
});

test('missing or invalid dates have an explicit fallback', () => {
  for (const value of [null, undefined, '', 'invalid', '2026-02-30', '2026-13-01',
    '2026-11-05Tinvalid', '2026-02-29', 0]) {
    assert.equal(formatDate(value), 'Not available');
  }
});
