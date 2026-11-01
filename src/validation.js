// Order numbers are ORD- followed by exactly six digits, for example ORD-100232.
const ORDER_ID = /^ORD-\d{6}$/;

export function isValidOrderId(value) {
  return typeof value === 'string' && ORDER_ID.test(value);
}
