# Prompts and prepared text for the live demo

Copy-paste text for each step of [the live demo guide](LIVE-DEMO-GUIDE.md). Replace `<owner>/<repo>` and the issue numbers with yours.

## 0. Business requirement

Read it aloud at the start, and paste it into prompt 1.

> Our agents answer a lot of "where is my order?" calls, and today they search several systems to find one order. We need a simple **Order Desk**: an agent types an order number and immediately sees the order status and estimated delivery date. Unknown or mistyped numbers must show a clear message. Agents must not see payment details, and every lookup must be recorded for audit.

## 1. Create the issue with Copilot

Where: <https://github.com/copilot> (Copilot Chat on GitHub.com). Creating issues with Copilot is in public preview.

```text
In <owner>/<repo>, create a feature issue from the requirement below using our Feature request form.
Write testable acceptance criteria, and create sub-issues for: (1) the order lookup API,
(2) the agent lookup page, (3) an audit log of every lookup.

Our agents answer a lot of "where is my order?" calls, and today they search several systems to find
one order. We need a simple Order Desk: an agent types an order number and immediately sees the order
status and estimated delivery date. Unknown or mistyped numbers must show a clear message. Agents must
not see payment details, and every lookup must be recorded for audit.
```

Expect a draft parent issue with the form's sections filled in, plus three draft sub-issues. Review and edit before you select **Create**.

## 2. Assign the page to Copilot

Where: sub-issue **Agent lookup page** → **Assignees → Copilot** → optional prompt.

```text
Build the agent lookup page in public/ with plain HTML, CSS and JavaScript. Another pull request is
building the API; code against this contract: GET /api/orders/:orderId returns 200 with
{ id, status, lastUpdated, estimatedDelivery }, 400 for invalid IDs and 404 with { error } when not found.
Do not add or change server routes. Use the Contoso design system in public/styles.css and keep the
existing top bar and footer. Show a clear message for unknown order numbers, make the form keyboard
accessible, and add unit tests for the formatting helpers.
```

## 3. Plan mode in VS Code

Where: Copilot Chat in VS Code, **Plan**, on branch `feature/order-lookup-api`.

```text
Plan the order lookup API from issue #13: GET /api/orders/:orderId returns id, status, lastUpdated and
estimatedDelivery from data/orders.json; 400 when the ID doesn't match ORD- plus six digits; 404 with a
JSON error for unknown IDs. List the files you will change and the tests you will add.
```

## 4. Agent mode in VS Code

Where: switch the same chat to **Agent**.

```text
Implement the plan. Then run npm test and fix any failures.
```

Then, in Source Control: **Generate commit message** → commit → push → create the pull request. Make sure the description contains:

```text
Fixes #13
```

## 5. Iterate on Copilot's pull request

Where: a comment on the cloud agent's pull request for the page.

```text
@copilot Show the estimated delivery date in a friendly format such as "5 Nov 2026", and add a test for it.
```

## 6. Prepared issue text (fallback for prompt 1)

Use **New issue → Feature request** and paste these, or run `scripts/create-demo-issues.sh` before the session.

**Title:** `[Feature]: Order Desk: look up an order's status and delivery date`

| Form field | Text |
|---|---|
| Business problem | Customer care agents answer a lot of "where is my order?" calls, and today they search several systems to find one order. |
| Desired outcome | A simple Order Desk: an agent types an order number and immediately sees the order status and estimated delivery date. |
| Acceptance criteria | - Given a valid order number (ORD- followed by six digits), the agent sees the order status and the estimated delivery date<br>- An unknown order number shows a clear "not found" message<br>- A mistyped order number shows a clear message that explains the expected format<br>- Agents never see payment details or customer contact details<br>- Every lookup is recorded for audit |
| Data sensitivity | Payment data |
| Non-functional requirements | A lookup answers in under one second. The page works with the keyboard and a screen reader. Lookups are recorded for audit. |

**Sub-issue 1: Order lookup API**

```markdown
Build `GET /api/orders/:orderId`, reading `data/orders.json`.

### Acceptance criteria

- 200 with only `id`, `status`, `lastUpdated` and `estimatedDelivery` for a known order
- 400 with `{ "error": "Order numbers look like ORD-123456" }` when the ID is not ORD- followed by six digits
- 404 with `{ "error": "Order not found" }` for an unknown order
- No payment or customer contact fields in any response
- Tests for success, 400 and 404
```

**Sub-issue 2: Agent lookup page**

```markdown
Replace the placeholder in `public/index.html` with an order lookup page for customer care agents.

### Acceptance criteria

- A labelled "Order number" field and a Look up button that work with the keyboard only
- Shows the status and estimated delivery date from `GET /api/orders/:orderId` (built in the API sub-issue): 200 returns `{ id, status, lastUpdated, estimatedDelivery }`, 400 and 404 return `{ error }`
- Unknown order numbers show a clear not-found message; mistyped ones explain the expected format
- Uses the Contoso design system in `public/styles.css`
- Unit tests for the formatting helpers
```

**Sub-issue 3: Audit log of order lookups** (stays open for Session 6)

```markdown
Record every order lookup for audit: who looked up which order, when, and the result.

### Acceptance criteria

- Each lookup writes an audit record with a timestamp, the agent's identity, the order number and the result (found, not found or invalid)
- Audit records never contain customer contact or payment details
- Audit records can be listed for one order number
```

## 7. Order numbers to try in the live app

| Order | What it shows |
|---|---|
| `ORD-100232` | Out for delivery, arriving on the demo day |
| `ORD-100231` | Packed, delivery in two days |
| `ORD-100233` | Delivered two days ago |
| `ORD-100234` | Payment pending, delivery not scheduled yet |
| `ORD-999999` | Not found |
| `12345` | Invalid format |
| `100232` | The page accepts the six digits alone and fills in `ORD-` |

Dates are relative to the demo day the data was generated for (3 November 2026 by default). To make "today" match your demo, run `DEMO_DATE=YYYY-MM-DD APPROVER=<approver> scripts/github-setup.sh` a few days before: it regenerates `data/orders.json` for that day, commits it to main, and moves the `demo-start` tag. Then redeploy (Actions → CI/CD → Run workflow).
