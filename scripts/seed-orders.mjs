#!/usr/bin/env node
// Generates synthetic e-commerce orders for Contoso Order Desk (data/orders.json).
//
//   npm run seed                          # demo day 2026-11-03 (matches the workshop replay)
//   npm run seed -- --date 2026-11-20     # move every date so the demo looks current on the day
//
// The four scripted demo orders keep their numbers and statuses:
//   ORD-100231 Packed · ORD-100232 Out for delivery (arrives on the demo day) · ORD-100233 Delivered · ORD-100234 Payment pending
// Every name, email address, phone number and card number is made up. Emails use example.com.
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    date: { type: 'string', default: '2026-11-03' },
    count: { type: 'string', default: '36' },
    seed: { type: 'string', default: '2026' },
    out: { type: 'string', default: fileURLToPath(new URL('../data/orders.json', import.meta.url)) }
  }
});

const DAY = 24 * 60 * 60 * 1000;
const demoDay = new Date(`${values.date}T00:00:00Z`);
if (Number.isNaN(demoDay.getTime())) {
  console.error('Use --date YYYY-MM-DD');
  process.exit(1);
}

// Small deterministic PRNG so the same seed always gives the same file.
let state = Number(values.seed) >>> 0 || 1;
function random() {
  state = (state + 0x6d2b79f5) >>> 0;
  let t = state;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (list) => list[Math.floor(random() * list.length)];
const between = (min, max) => min + Math.floor(random() * (max - min + 1));

const day = (offset) => new Date(demoDay.getTime() + offset * DAY);
const isoDate = (d) => d.toISOString().slice(0, 10);
const isoTime = (d, hh, mm) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), hh, mm)).toISOString().replace('.000Z', 'Z');

const PRODUCTS = [
  { sku: 'CTS-AUD-0042', name: 'Wireless noise-cancelling headphones', unitPrice: 1899000 },
  { sku: 'CTS-KIT-0107', name: 'Stainless steel kettle 1.7 L', unitPrice: 459000 },
  { sku: 'CTS-HOM-0215', name: 'Linen bedding set, queen', unitPrice: 1249000 },
  { sku: 'CTS-ELE-0330', name: 'USB-C charging hub, 7-in-1', unitPrice: 649000 },
  { sku: 'CTS-SPT-0418', name: 'Running shoes', unitPrice: 1099000 },
  { sku: 'CTS-SPT-0419', name: 'Yoga mat, 6 mm', unitPrice: 329000 },
  { sku: 'CTS-BAG-0520', name: 'Carry-on suitcase, 55 cm', unitPrice: 1750000 },
  { sku: 'CTS-KIT-0634', name: "Chef's knife, 20 cm", unitPrice: 899000 },
  { sku: 'CTS-ELE-0751', name: 'Smart LED bulb, 4-pack', unitPrice: 479000 },
  { sku: 'CTS-TOY-0812', name: 'Wooden building blocks, 120 pieces', unitPrice: 389000 },
  { sku: 'CTS-BTY-0905', name: 'Vitamin C serum, 30 ml', unitPrice: 259000 },
  { sku: 'CTS-OFF-1003', name: 'Ergonomic office chair', unitPrice: 3499000 }
];
const FIRST = ['Ayu', 'Budi', 'Citra', 'Dimas', 'Eka', 'Fajar', 'Gita', 'Hana', 'Indra', 'Joko', 'Kirana', 'Lukas', 'Maya', 'Nadia', 'Oscar', 'Putri', 'Rizky', 'Sari', 'Tomas', 'Wulan'];
const LAST = ['Santoso', 'Wijaya', 'Pratama', 'Lestari', 'Hidayat', 'Nugroho', 'Kusuma', 'Halim', 'Tanjung', 'Saputra', 'Gunawan', 'Siregar'];
const CITIES = ['Jakarta', 'Surabaya', 'Bandung', 'Medan', 'Denpasar', 'Makassar', 'Yogyakarta', 'Semarang'];
const CARRIERS = ['Contoso Express', 'Northwind Logistics', 'Fabrikam Freight'];
const CARD = ['Visa', 'Mastercard'];

function customer() {
  const first = pick(FIRST);
  const last = pick(LAST);
  return {
    name: `${first} ${last}`,
    email: `${first}.${last}@example.com`.toLowerCase(),
    phone: `+62 21 5550 ${String(between(100, 999)).padStart(4, '0')}`
  };
}

function basket() {
  const lines = [];
  const used = new Set();
  const n = between(1, 3);
  while (lines.length < n) {
    const p = pick(PRODUCTS);
    if (used.has(p.sku)) continue;
    used.add(p.sku);
    lines.push({ sku: p.sku, name: p.name, quantity: between(1, 2), unitPrice: p.unitPrice });
  }
  const subtotal = lines.reduce((sum, l) => sum + l.quantity * l.unitPrice, 0);
  const shippingFee = subtotal >= 1500000 ? 0 : 25000;
  return { items: lines, totals: { currency: 'IDR', subtotal, shippingFee, total: subtotal + shippingFee } };
}

function order({ id, status, placed, updated, eta, channel }) {
  const { items, totals } = basket();
  const paid = status !== 'Payment pending';
  return {
    id,
    status,
    placedAt: placed,
    lastUpdated: updated,
    estimatedDelivery: eta,
    channel: channel || pick(['web', 'app', 'web', 'marketplace']),
    customer: customer(),
    shipping: {
      city: pick(CITIES),
      country: 'ID',
      carrier: pick(CARRIERS),
      trackingNumber: ['Packed', 'Payment pending', 'Cancelled'].includes(status) ? null : `CX${between(10000000, 99999999)}ID`
    },
    items,
    totals,
    payment: { method: pick(CARD), last4: String(between(1000, 9999)), status: paid ? (status === 'Cancelled' ? 'refunded' : 'captured') : 'pending' }
  };
}

// The scripted orders used in the live demo. Times match the workshop replay when --date is 2026-11-03.
const scripted = [
  order({ id: 'ORD-100231', status: 'Packed', placed: isoTime(day(-2), 3, 12), updated: isoTime(day(-1), 8, 15), eta: isoDate(day(2)), channel: 'web' }),
  order({ id: 'ORD-100232', status: 'Out for delivery', placed: isoTime(day(-3), 14, 2), updated: isoTime(day(0), 6, 40), eta: isoDate(day(0)), channel: 'app' }),
  order({ id: 'ORD-100233', status: 'Delivered', placed: isoTime(day(-6), 9, 48), updated: isoTime(day(-2), 12, 5), eta: isoDate(day(-2)), channel: 'web' }),
  order({ id: 'ORD-100234', status: 'Payment pending', placed: isoTime(day(0), 9, 21), updated: isoTime(day(0), 9, 30), eta: null, channel: 'marketplace' })
];

const STATUS_MIX = [
  ['Payment pending', 1], ['Packed', 2], ['Shipped', 3], ['Out for delivery', 2], ['Delivered', 4], ['Cancelled', 1]
];
function randomStatus() {
  const total = STATUS_MIX.reduce((s, [, w]) => s + w, 0);
  let r = random() * total;
  for (const [status, w] of STATUS_MIX) {
    if ((r -= w) < 0) return status;
  }
  return 'Delivered';
}

const taken = new Set(scripted.map((o) => o.id));
taken.add('ORD-999999'); // must stay unknown: the demo uses it for the "not found" case
const at = (offset, minutes) => new Date(day(offset).getTime() + minutes * 60000);
const stamp = (d) => d.toISOString().replace('.000Z', 'Z');
const generated = [];
while (generated.length < Number(values.count)) {
  const id = `ORD-${between(100200, 100299)}`;
  if (taken.has(id)) continue;
  taken.add(id);
  const status = randomStatus();
  const placedOffset = status === 'Payment pending' ? -between(0, 1) : -between(2, 10);
  const placed = at(placedOffset, between(6 * 60, 22 * 60));
  let updatedOffset;
  let eta;
  switch (status) {
    case 'Payment pending': updatedOffset = placedOffset; eta = null; break;
    case 'Packed': updatedOffset = between(placedOffset + 1, 0); eta = between(1, 4); break;
    case 'Shipped': updatedOffset = between(placedOffset + 1, 0); eta = between(1, 3); break;
    case 'Out for delivery': updatedOffset = 0; eta = 0; break;
    case 'Delivered': eta = between(placedOffset + 2, 0); updatedOffset = eta; break;
    default: updatedOffset = between(placedOffset, 0); eta = null; // Cancelled
  }
  let updated = at(updatedOffset, between(6 * 60, 20 * 60));
  if (updated <= placed) updated = new Date(placed.getTime() + between(20, 240) * 60000);
  generated.push(order({ id, status, placed: stamp(placed), updated: stamp(updated), eta: eta === null ? null : isoDate(day(eta)) }));
}

const all = [...scripted, ...generated].sort((a, b) => a.id.localeCompare(b.id));
writeFileSync(values.out, `${JSON.stringify(all, null, 2)}\n`);
console.log(`Wrote ${all.length} synthetic orders for demo day ${values.date} to ${values.out}`);
