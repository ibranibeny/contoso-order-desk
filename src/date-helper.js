// Demo branch demo/add-date-helper: adds a package version with published security advisories
// so the dependency review check can block it. Never merge it.
import _ from 'lodash';

const DAY_MS = 24 * 60 * 60 * 1000;

// Calendar dates from the estimated delivery date to a few days after it.
export function deliveryWindow(isoDate, extraDays = 2) {
  const start = new Date(`${isoDate}T00:00:00Z`).getTime();
  return _.range(extraDays + 1).map((offset) => new Date(start + offset * DAY_MS).toISOString().slice(0, 10));
}
