#!/usr/bin/env bash
# Fallback for Act 1: creates the feature issue and its three sub-issues with the prepared text, in case
# creating issues with Copilot (public preview) is unavailable. Also handy for rehearsals.
#
#   PROJECT=OWNER/NUMBER scripts/create-demo-issues.sh     # also adds the issues to that project
#
# Needs: gh with write access (and the project scope for PROJECT: gh auth refresh -s project).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
need gh
resolve_repo

new_issue() { # title body-file -> prints "number id url"
  gh api "repos/$REPO/issues" -f title="$1" -F body=@"$2" -f 'labels[]=enhancement' --jq '"\(.number) \(.id) \(.html_url)"'
}
add_sub_issue() { # parent-number child-id
  gh api -X POST "repos/$REPO/issues/$1/sub_issues" -F sub_issue_id="$2" --silent \
    || warn "Could not link the sub-issue automatically; add it from the parent issue (Create sub-issue > Add existing issue)."
}
add_to_project() { # url
  [ -n "${PROJECT:-}" ] || return 0
  gh project item-add "${PROJECT##*/}" --owner "${PROJECT%%/*}" --url "$1" >/dev/null \
    || warn "Could not add $1 to project $PROJECT."
}
set_type() { # number
  [ -n "${ISSUE_TYPE:-}" ] || return 0
  gh api -X PATCH "repos/$REPO/issues/$1" -f type="$ISSUE_TYPE" --silent 2>/dev/null \
    || warn "Could not set the issue type (issue types exist only in organizations)."
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/parent.md" <<'MD'
### Business problem

Customer care agents answer a lot of "where is my order?" calls, and today they search several systems to find one order.

### Desired outcome

A simple Order Desk: an agent types an order number and immediately sees the order status and estimated delivery date.

### Acceptance criteria

- Given a valid order number (ORD- followed by six digits), the agent sees the order status and the estimated delivery date
- An unknown order number shows a clear "not found" message
- A mistyped order number shows a clear message that explains the expected format
- Agents never see payment details or customer contact details
- Every lookup is recorded for audit

### Data sensitivity

Payment data

### Non-functional requirements

A lookup answers in under one second. The page works with the keyboard and a screen reader. Lookups are recorded for audit.
MD
OUT=$(new_issue "[Feature]: Order Desk: look up an order's status and delivery date" "$TMP/parent.md") || die "Could not create the issue [Feature]: Order Desk: look up an order's status and delivery date."
read -r PARENT PARENT_ID PARENT_URL <<< "$OUT"
ok "Feature issue #$PARENT $PARENT_URL"
set_type "$PARENT"
add_to_project "$PARENT_URL"

cat > "$TMP/api.md" <<MD
Part of #$PARENT.

Build \`GET /api/orders/:orderId\`, reading \`data/orders.json\`.

### Acceptance criteria

- 200 with only \`id\`, \`status\`, \`lastUpdated\` and \`estimatedDelivery\` for a known order
- 400 with \`{ "error": "Order numbers look like ORD-123456" }\` when the ID is not ORD- followed by six digits
- 404 with \`{ "error": "Order not found" }\` for an unknown order
- No payment or customer contact fields in any response
- Tests for success, 400 and 404
MD
OUT=$(new_issue "Order lookup API" "$TMP/api.md") || die "Could not create the issue Order lookup API."
read -r API API_ID API_URL <<< "$OUT"
add_sub_issue "$PARENT" "$API_ID"
add_to_project "$API_URL"
ok "Sub-issue #$API Order lookup API"

cat > "$TMP/page.md" <<MD
Part of #$PARENT.

Replace the placeholder in \`public/index.html\` with an order lookup page for customer care agents.

### Acceptance criteria

- A labelled "Order number" field and a Look up button that work with the keyboard only
- Shows the status and estimated delivery date from \`GET /api/orders/:orderId\` (built in #$API): 200 returns \`{ id, status, lastUpdated, estimatedDelivery }\`, 400 and 404 return \`{ error }\`
- Unknown order numbers show a clear not-found message; mistyped ones explain the expected format
- Uses the Contoso design system in \`public/styles.css\`
- Unit tests for the formatting helpers
MD
OUT=$(new_issue "Agent lookup page" "$TMP/page.md") || die "Could not create the issue Agent lookup page."
read -r PAGE PAGE_ID PAGE_URL <<< "$OUT"
add_sub_issue "$PARENT" "$PAGE_ID"
add_to_project "$PAGE_URL"
ok "Sub-issue #$PAGE Agent lookup page"

cat > "$TMP/audit.md" <<MD
Part of #$PARENT.

Record every order lookup for audit: who looked up which order, when, and the result.

### Acceptance criteria

- Each lookup writes an audit record with a timestamp, the agent's identity, the order number and the result (found, not found or invalid)
- Audit records never contain customer contact or payment details
- Audit records can be listed for one order number
MD
OUT=$(new_issue "Audit log of order lookups" "$TMP/audit.md") || die "Could not create the issue Audit log of order lookups."
read -r AUDIT AUDIT_ID AUDIT_URL <<< "$OUT"
add_sub_issue "$PARENT" "$AUDIT_ID"
add_to_project "$AUDIT_URL"
ok "Sub-issue #$AUDIT Audit log of order lookups (stays open for Session 6)"

step "Done"
info "Next in the demo: assign #$PAGE to Copilot with the optional prompt from docs/PROMPTS.md, then build #$API in VS Code."
