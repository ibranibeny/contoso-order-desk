#!/usr/bin/env bash
# Opens the two pull requests for the security gate (Act 4). Run it at least 30 minutes before the demo,
# so CodeQL and dependency review have finished when you show them. Safe to run again.
#
#   demo/not-found-message  adds a deliberately unsafe handler -> CodeQL reports cross-site scripting,
#                           Copilot Autofix proposes a fix
#   demo/add-date-helper    adds lodash 4.17.15, a version with published advisories -> Dependency Review fails
#
# Both branches are rebuilt from the current origin/main each time, so the diff shows only the demo change.
# Never merge these pull requests; close them after the demo (scripts/reset-demo.sh does).
#
# Needs: gh (write access), git, node and npm (with access to the npm registry).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
need gh; need git; need npm
resolve_repo
ensure_git_identity

WORK=$(mktemp -d)
cleanup() { git worktree remove --force "$WORK" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
git fetch -q origin main
git worktree add -q --detach "$WORK" origin/main

open_pr() { # branch title body
  local number
  number=$(gh pr list -R "$REPO" --head "$1" --state open --json number --jq '.[0].number // empty')
  if [ -n "$number" ]; then
    ok "Pull request #$number already open for $1 (updated with the new commit)"
  else
    gh pr create -R "$REPO" --base main --head "$1" --title "$2" --body "$3" >/dev/null
    ok "Opened: $(gh pr list -R "$REPO" --head "$1" --state open --json number,url --jq '.[0] | "#\(.number) \(.url)"')"
  fi
}

step "1/2 demo/not-found-message (code scanning + Copilot Autofix)"
(
  cd "$WORK"
  git switch -q -C demo/not-found-message origin/main
  cat >> src/app.js <<'JS'

// DELIBERATELY UNSAFE (demo branch demo/not-found-message). It exists only to show
// code scanning and Copilot Autofix in a pull request. Never merge it.
app.get('/orders/lookup', (req, res) => {
  const id = req.query.id;
  const order = orders.find((o) => o.id === id);
  if (!order) {
    return res.send(`<p>No order found for ${id}</p>`);
  }
  res.json(order);
});
JS
  git commit -q -am "Show a not-found message for order lookups"
  git push -q -f origin demo/not-found-message
)
open_pr demo/not-found-message "Show a not-found message for order lookups" \
"Adds \`GET /orders/lookup?id=\` that tells the agent when an order is not found.

> **Demo pull request for the security gate.** It is deliberately unsafe so that code scanning and Copilot Autofix have something to find. Never merge it; close it after the demo."

step "2/2 demo/add-date-helper (dependency review)"
(
  cd "$WORK"
  git switch -q -C demo/add-date-helper origin/main
  npm install --no-audit --no-fund --update-notifier=false --save-exact lodash@4.17.15 >/dev/null
  cat > src/date-helper.js <<'JS'
// Demo branch demo/add-date-helper: adds a package version with published security advisories
// so the dependency review check can block it. Never merge it.
import _ from 'lodash';

const DAY_MS = 24 * 60 * 60 * 1000;

// Calendar dates from the estimated delivery date to a few days after it.
export function deliveryWindow(isoDate, extraDays = 2) {
  const start = new Date(`${isoDate}T00:00:00Z`).getTime();
  return _.range(extraDays + 1).map((offset) => new Date(start + offset * DAY_MS).toISOString().slice(0, 10));
}
JS
  git add package.json package-lock.json src/date-helper.js
  git commit -q -m "Add date helper dependency"
  git push -q -f origin demo/add-date-helper
)
open_pr demo/add-date-helper "Add a date helper for delivery windows" \
"Adds a small helper that lists the days in a delivery window, using lodash.

> **Demo pull request for dependency review.** It adds a package version with published security advisories. Never merge it; close it after the demo."

step "Done"
info "Wait until both pull requests show their checks (CodeQL takes a few minutes), then run scripts/preflight.sh."
