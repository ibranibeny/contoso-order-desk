// Agents may see only these fields. Customer contact and payment data never leave the server.
export const SUMMARY_FIELDS = ['id', 'status', 'lastUpdated', 'estimatedDelivery'];

export function findOrder(orders, orderId) {
  return orders.find((order) => order.id === orderId);
}

export function toOrderSummary(order) {
  return Object.fromEntries(SUMMARY_FIELDS.map((field) => [field, order[field] ?? null]));
}
