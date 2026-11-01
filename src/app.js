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
