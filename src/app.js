import express from 'express';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const dataFile = fileURLToPath(new URL('../data/orders.json', import.meta.url));
const publicDir = fileURLToPath(new URL('../public', import.meta.url));
const orders = JSON.parse(readFileSync(dataFile, 'utf8'));

export const app = express();
app.disable('x-powered-by');
app.use(express.static(publicDir));

app.get('/health', (req, res) => {
  res.json({ status: 'ok', orders: orders.length });
});

// DELIBERATELY UNSAFE (demo branch demo/not-found-message). It exists only to show
// code scanning and Copilot Autofix in a pull request. Never merge it.
app.get('/orders/lookup', (req, res) => {
  const id = req.query.id;
  const order = orders.find((o) => o.id === id);
  if (!order) {
    return res.status(404).json({ error: 'Order not found' });
  }
  res.json({
    id: order.id,
    status: order.status,
    estimatedDelivery: order.estimatedDelivery
  });
});
