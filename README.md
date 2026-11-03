# Contoso Order Desk · live demo kit

[![CI/CD](https://github.com/ibranibeny/contoso-order-desk/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/ibranibeny/contoso-order-desk/actions/workflows/ci-cd.yml)

Starter repository for **Session 5 of the Contoso × GitHub workshop: "From business requirement to production"**.
You run the demo for real with it: a business requirement becomes an issue, Copilot builds the API (VS Code agent mode) and the page (Copilot cloud agent) in parallel, Copilot and a human review, CodeQL with Copilot Autofix and dependency review gate the merge, and GitHub Actions deploys to Azure App Service with an approval and OpenID Connect.

- **Step-by-step guide:** [docs/LIVE-DEMO-GUIDE.md](docs/LIVE-DEMO-GUIDE.md) (setup, run of show, fallbacks, reset, troubleshooting)
- **Copy-paste prompts:** [docs/PROMPTS.md](docs/PROMPTS.md)
- **What it looks like when it works:** the simulated [demo replay](https://ibranibeny.github.io/contoso-github-ai-workshop/replay.html?demo=live-demo) and the [workshop site](https://ibranibeny.github.io/contoso-github-ai-workshop/05-live-demo.html)

![Order Desk after the demo: looking up ORD-100232, out for delivery today](docs/images/order-lookup.png)

| Before the demo (main) | Unknown order | Dark mode |
|---|---|---|
| ![Placeholder page on main](docs/images/start.png) | ![Not found message for ORD-999999](docs/images/not-found.png) | ![Delivered order in dark mode](docs/images/dark.png) |

Screenshots are taken automatically from the `solution` branch, with the demo day set to 3 November 2026.

## Run it in four steps

1. **Create your copy:** **Use this template → Create a new repository**, and tick **Include all branches**.
2. **Configure GitHub:** `scripts/github-setup.sh` (settings, security, environment, ruleset, project). One account by default: you approve the deployment yourself. With a second person: `APPROVER=<second-person> scripts/github-setup.sh`.
3. **Create Azure:** `scripts/azure-setup.sh` in Azure Cloud Shell (App Service, managed identity with OIDC, secrets), then approve the first deployment (you, or the approver).
4. **Before each session:** `scripts/prepare-security-prs.sh`, then `scripts/preflight.sh`. Afterwards: `scripts/reset-demo.sh`.

Details, licences and the two-person setup are in the [guide](docs/LIVE-DEMO-GUIDE.md#1-what-you-need).

## Try the app locally

```bash
npm ci
npm test
npm start                    # http://localhost:3000 shows the placeholder page (the demo starts here)
git switch solution && npm start   # the finished Order Desk: try ORD-100232, ORD-999999 and 12345
```

Node.js 24 and Express 5. Tests use the built-in `node --test` runner.

## Branches

| Branch | What it is | Used in |
|---|---|---|
| `main` | The starting point: health endpoint, synthetic orders, design system, placeholder page, Copilot instructions, workflows | Whole demo (tag `demo-start`) |
| `fallback/order-lookup-api` | A finished `GET /api/orders/:orderId` with tests | Act 2, if agent mode stalls |
| `fallback/agent-lookup-page` | A finished lookup page with tests | Act 3, if the cloud agent is not ready |
| `solution` | Both, merged: what main looks like after the demo | Rehearsal reference, screenshots |
| `demo/not-found-message` | A deliberately unsafe handler (reflected XSS) | Act 4: CodeQL and Copilot Autofix. Never merge |
| `demo/add-date-helper` | Adds `lodash@4.17.15`, a version with published advisories | Act 4: dependency review. Never merge |

## Scripts

| Script | When | What it does |
|---|---|---|
| `scripts/github-setup.sh` | Once | Repository settings, approver access (two people only), project, CODEOWNERS, security features, `production` environment, ruleset, `demo-start` tag |
| `scripts/azure-setup.sh` | Once (Cloud Shell) | App Service (Linux, Node.js 24), Application Insights, user-assigned managed identity with a federated credential for the `production` environment, environment secrets, first deployment |
| `scripts/prepare-security-prs.sh` | 60 min before | Opens the two security pull requests from the current main |
| `scripts/preflight.sh` | 30 min before | Read-only readiness check |
| `scripts/create-demo-issues.sh` | Fallback | Creates the feature issue and its three sub-issues if creating issues with Copilot is unavailable |
| `scripts/push-protection-demo.sh` | Optional | Shows push protection blocking a made-up "Contoso demo token" (organization with a custom pattern) |
| `scripts/reset-demo.sh` | After each run | Closes pull requests and issues, deletes demo branches, moves main back to `demo-start` |
| `scripts/cleanup-azure.sh` | After the workshop | Deletes the Azure resource group and the Azure settings in GitHub |
| `npm run seed -- --date YYYY-MM-DD` | Any time | Regenerates the synthetic orders relative to a demo day |

## Agentic SDLC

The demo walks one loop, and two [GitHub Agentic Workflows](https://github.github.com/gh-aw/) keep it turning every day:

| Stage | Who does the work | Where |
|---|---|---|
| Plan | Copilot drafts the feature issue and its sub-issues from the business requirement | Issues, feature request form |
| Code | Copilot cloud agent on an assigned issue, agent mode in VS Code | Pull requests |
| Review | Copilot code review on every push, then a person; unresolved threads block the merge | Ruleset `Protect main` |
| Secure | CodeQL with Copilot Autofix, dependency review, secret scanning with push protection, Dependabot | GitHub Advanced Security |
| Build and deploy | Tests on every pull request, deployment after an approval with OIDC | `ci-cd.yml`, environment `production` |
| Operate | **Daily SDLC health** raises an issue for each problem on main: assign it to Copilot and the loop starts again. **Daily activity report** sums up the day | Agentic workflows below |

Both workflows need the repository secret `COPILOT_GITHUB_TOKEN`, a fine-grained personal access token of a Copilot user with the account permission **Copilot Requests: Read** ([how](https://github.github.com/gh-aw/reference/auth/#copilot_github_token)). Run one now with **Actions → *workflow name* → Run workflow**. They run only in `ibranibeny/contoso-order-desk`: in a copy of this template, put your repository in their `if:` line, recompile with `gh aw compile` (`gh extension install github/gh-aw`), and commit each `.md` with its generated `.lock.yml`. The prompts that created them are in [docs/PROMPTS.md](docs/PROMPTS.md#8-agentic-workflows).

### Daily SDLC health

[`.github/workflows/daily-sdlc-health.md`](.github/workflows/daily-sdlc-health.md) runs every day at 23:31 UTC (06:31 in UTC+7). First [`.github/scripts/daily-sdlc-health.sh`](.github/scripts/daily-sdlc-health.sh) checks, with `gh` and `jq` and no AI:

- **Build:** the latest runs of every workflow on main, and runs waiting for an approval.
- **Code review:** open pull requests with unresolved review threads, changes requested, failing checks or conflicts, waiting more than a day for a review, or idle for a week.
- **GitHub Advanced Security:** open code scanning alerts and the age of the last analysis, Dependabot alerts, and secret scanning alerts.

When something needs fixing, Copilot raises `[agentic-sdlc] SDLC health report, …` (label `report`) and one `[agentic-sdlc]` issue per new problem on main, with the evidence, a suggested fix and when it counts as done. Assign a fix issue to Copilot to get a pull request. The next check replaces the report and closes the fix issues whose problem is gone; a healthy day writes nothing. `scripts/preflight.sh` ignores the report but counts open fix issues, since they mean main has a problem.

Secret scanning alerts need the optional repository secret `SECRET_SCANNING_TOKEN`: a fine-grained personal access token with access to this repository and the permission **Secret scanning alerts: Read**. Without it, the report says secret scanning was not checked. Secret values are never read.

### Daily activity report

[`.github/workflows/daily-activity-report.md`](.github/workflows/daily-activity-report.md) runs every day at 01:16 UTC (08:16 in UTC+7). A setup step collects the last 24 hours of commits on main, pull requests, issues, releases and workflow runs, and Copilot posts a summary as an issue labelled `report` (`[daily-activity] Repository activity for …`). A quiet day posts nothing, each new report closes the previous one, and reports close themselves after 7 days (the generated `agentics-maintenance.yml` does that). `scripts/preflight.sh` ignores open reports; `scripts/reset-demo.sh` closes them.

## What's inside

```text
.github/
  copilot-instructions.md          Contoso's rules for every Copilot surface
  instructions/tests.instructions.md
  agents/test-coverage-improver.agent.md
  ISSUE_TEMPLATE/feature-request.yml
  CODEOWNERS, dependabot.yml, pull_request_template.md
  workflows/ci-cd.yml              build + test, then deploy with approval and OIDC
  workflows/dependency-review.yml
  workflows/copilot-setup-steps.yml
  workflows/daily-activity-report.md  agentic workflow: the daily activity report (compiled to .lock.yml)
  workflows/daily-sdlc-health.md   agentic workflow: the daily SDLC health check (compiled to .lock.yml)
  scripts/daily-sdlc-health.sh     its checks of builds, reviews and security alerts (gh + jq, no AI)
  workflows/agentics-maintenance.yml  generated by gh aw: closes expired reports
data/orders.json                   40 synthetic e-commerce orders (example.com addresses, 555 phone numbers)
public/                            design system (styles.css) and the placeholder page
scripts/                           setup, demo and reset scripts
src/, test/                        Express 5 app and tests
docs/                              guide, prompts, screenshots
```

## Data and privacy

All orders, names, emails, phone numbers and card digits are generated by `scripts/seed-orders.mjs` and are fictitious. Contoso, Northwind and Fabrikam are fictitious companies used in Microsoft examples.

## Status

Before publishing, every branch was installed and tested on a GitHub-hosted runner with Node.js 24 and Express 5: `main` (1 test), `fallback/order-lookup-api` (8), `fallback/agent-lookup-page` (10), `solution` (18) and both demo branches (1 each), all passing. The finished app was started on the runner and checked in headless Chrome, which also took the screenshots above. CI/CD runs on main and on every pull request.

The setup scripts were checked end to end against stand-in `gh` and `az` commands, not against a real organization and subscription, and the deploy job has not yet run against Azure: run them in a rehearsal first. See [what has been tested](docs/LIVE-DEMO-GUIDE.md#7-what-has-been-tested-and-what-you-must-check-in-rehearsal).
