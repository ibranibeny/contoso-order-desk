import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isValidOrderId } from '../src/validation.js';

test('accepts ORD- followed by six digits', () => {
  assert.equal(isValidOrderId('ORD-100232'), true);
  assert.equal(isValidOrderId('ORD-000001'), true);
});

test('rejects anything else', () => {
  const invalid = ['12345', '100232', 'ORD-12345', 'ORD-1234567', 'ord-100232', ' ORD-100232', 'ORD-10023A', 'ORD_100232', '', null, undefined, 100232];
  for (const value of invalid) {
    assert.equal(isValidOrderId(value), false, `expected ${JSON.stringify(value)} to be rejected`);
  }
});
