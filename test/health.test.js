import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { app } from '../src/app.js';

test('GET /health reports ok and the number of orders loaded', async () => {
  const server = app.listen(0);
  if (!server.listening) await once(server, 'listening');
  try {
    const { port } = server.address();
    const res = await fetch(`http://127.0.0.1:${port}/health`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, 'ok');
    assert.ok(body.orders > 0);
  } finally {
    server.close();
  }
});
