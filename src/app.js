import express from 'express';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { findOrder, toOrderSummary } from './orders.js';
import { isValidOrderId } from './validation.js';

const dataFile = fileURLToPath(new URL('../data/orders.json', import.meta.url));
const publicDir = fileURLToPath(new URL('../public', import.meta.url));
const orders = JSON.parse(readFileSync(dataFile, 'utf8'));

export const app = express();
app.disable('x-powered-by');
app.use(express.static(publicDir));

app.get('/health', (req, res) => {
  res.json({ status: 'ok', orders: orders.length });
});

app.get('/api/orders/:orderId', (req, res) => {
  const orderId = req.params.orderId.trim();
  res.set('Cache-Control', 'no-store');
  if (!isValidOrderId(orderId)) {
    return res.status(400).json({ error: 'Order numbers look like ORD-123456' });
  }
  const order = findOrder(orders, orderId);
  if (!order) {
    return res.status(404).json({ error: 'Order not found' });
  }
  res.json(toOrderSummary(order));
});

// Unknown API routes answer in JSON, like the rest of the API.
app.use('/api', (req, res) => {
  res.status(404).json({ error: 'Not found' });
});
