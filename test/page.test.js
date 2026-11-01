import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  STEPS,
  normalizeOrderId,
  isValidOrderId,
  stepIndex,
  trackerSteps,
  badgeVariant,
  formatDate,
  formatDateTime,
  timeZoneLabel,
  relativeDay,
  deliverySummary
} from '../public/format.js';

test('normalizeOrderId tidies what agents type', () => {
  assert.equal(normalizeOrderId(' ord-100232 '), 'ORD-100232');
  assert.equal(normalizeOrderId('100232'), 'ORD-100232');
  assert.equal(normalizeOrderId('ORD100232'), 'ORD-100232');
  assert.equal(normalizeOrderId('ORD 100 232'), 'ORD-100232');
  assert.equal(normalizeOrderId('12345'), '12345');
  assert.equal(normalizeOrderId(undefined), '');
});

test('isValidOrderId uses the same rule as the API', () => {
  assert.equal(isValidOrderId('ORD-100232'), true);
  for (const value of ['12345', 'ORD-12345', 'ord-100232', '', null]) {
    assert.equal(isValidOrderId(value), false);
  }
});

test('stepIndex places each status on the delivery tracker', () => {
  assert.equal(STEPS[stepIndex('Out for delivery')], 'Out for delivery');
  assert.equal(STEPS[stepIndex('Packed')], 'Packed');
  assert.equal(stepIndex('Payment pending'), 1);
  assert.equal(stepIndex('Delivered'), STEPS.length - 1);
  assert.equal(stepIndex('Cancelled'), -1);
  assert.equal(stepIndex('Lost in space'), -1);
});

test('trackerSteps marks done, current and upcoming steps', () => {
  const out = trackerSteps('Out for delivery');
  assert.deepEqual(out.map((s) => s.state), ['done', 'done', 'done', 'done', 'current', 'todo']);
  assert.deepEqual(trackerSteps('Payment pending')[1], { label: 'Awaiting payment', state: 'current' });
  assert.ok(trackerSteps('Delivered').every((s) => s.state === 'done'));
  assert.deepEqual(trackerSteps('Cancelled'), []);
});

test('badgeVariant picks a colour for every known status', () => {
  assert.equal(badgeVariant('Out for delivery'), 'out');
  assert.equal(badgeVariant('Delivered'), 'delivered');
  assert.equal(badgeVariant('Cancelled'), 'cancelled');
  assert.equal(badgeVariant('Something new'), 'neutral');
});

test('formatDate shows the day, short month and year', () => {
  assert.equal(formatDate('2026-11-05'), '5 Nov 2026');
  assert.equal(formatDate('2026-12-31'), '31 Dec 2026');
  assert.equal(formatDate(null), '');
  assert.equal(formatDate('soon'), '');
});

test('formatDateTime and timeZoneLabel use the time zone they are given', () => {
  assert.equal(formatDateTime('2026-11-03T06:40:00Z', { timeZone: 'UTC' }), '3 Nov 2026, 06:40');
  assert.equal(formatDateTime('2026-11-03T06:40:00Z', { timeZone: 'Asia/Jakarta' }), '3 Nov 2026, 13:40');
  assert.equal(timeZoneLabel('2026-11-03T06:40:00Z', { timeZone: 'Asia/Jakarta' }), 'GMT+7');
  assert.equal(formatDateTime('not a time'), '');
});

test('relativeDay describes dates within two weeks', () => {
  assert.equal(relativeDay('2026-11-03', '2026-11-03'), 'Today');
  assert.equal(relativeDay('2026-11-04', '2026-11-03'), 'Tomorrow');
  assert.equal(relativeDay('2026-11-02', '2026-11-03'), 'Yesterday');
  assert.equal(relativeDay('2026-11-05', '2026-11-03'), 'In 2 days');
  assert.equal(relativeDay('2026-10-30', '2026-11-03'), '4 days ago');
  assert.equal(relativeDay('2026-12-25', '2026-11-03'), '');
});

test('deliverySummary covers delivered, cancelled, unscheduled and upcoming orders', () => {
  const today = '2026-11-03';
  assert.deepEqual(deliverySummary({ status: 'Out for delivery', estimatedDelivery: '2026-11-03' }, today),
    { label: 'Estimated delivery', value: '3 Nov 2026', note: 'Today' });
  assert.deepEqual(deliverySummary({ status: 'Delivered', estimatedDelivery: '2026-11-01' }, today),
    { label: 'Delivered', value: '1 Nov 2026', note: '2 days ago' });
  assert.equal(deliverySummary({ status: 'Cancelled', estimatedDelivery: null }, today).value, 'No delivery');
  assert.deepEqual(deliverySummary({ status: 'Payment pending', estimatedDelivery: null }, today),
    { label: 'Estimated delivery', value: 'Not scheduled yet', note: 'Scheduled once payment is confirmed' });
});
