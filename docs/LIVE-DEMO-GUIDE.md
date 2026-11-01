# Live demo guide: from business requirement to production

This guide runs **Session 5 of the Contoso × GitHub workshop for real**, following the same ten chapters as the simulated replay:
[Demo replay · From business requirement to production](https://ibranibeny.github.io/contoso-github-ai-workshop/replay.html?demo=live-demo).

**Key message:** one business requirement reaches production in an hour. AI does much of the work, people decide, review and approve, and the platform enforces quality and security at every step.

> **AI output varies.** Copilot will not write exactly what it wrote in rehearsal. That is normal, and the demo is designed for it: every build step has a prepared fallback branch, and you review whatever Copilot produces live. Say this to the audience at the start.

**Contents**

1. [What you need](#1-what-you-need)
2. [One-time setup (about 45 minutes)](#2-one-time-setup-about-45-minutes)
3. [Before each demo](#3-before-each-demo)
4. [Run of show (60 minutes)](#4-run-of-show-60-minutes)
5. [After the demo](#5-after-the-demo)
6. [Troubleshooting](#6-troubleshooting)
7. [What has been tested, and what you must check in rehearsal](#7-what-has-been-tested-and-what-you-must-check-in-rehearsal)
8. [References](#8-references)

Copy-paste text for every prompt is in [PROMPTS.md](PROMPTS.md).

---

## 1. What you need

### People

| Role | Does what | Why it must be a second person |
|---|---|---|
| **Presenter** (developer and requester) | Drives the browser and VS Code, creates the issues, assigns work to Copilot, opens and merges pull requests | |
| **Approver** (reviewer and release manager) | On a second laptop or browser profile: approves workflow runs on Copilot's pull request, reviews and approves pull requests, approves the production deployment | The person who asks Copilot for work cannot approve the resulting pull request. Workflows on Copilot's pull requests wait for a user with write access to approve them. The production environment has *Prevent self-review* on. |
| Narrator (optional) | Keeps time, links each step back to Sessions 1–4 | |

### Where to run it: two options

| | **Option A: organization (recommended)** | **Option B: personal public repository (quickest)** |
|---|---|---|
| Repository | Private repository in an organization on GitHub Enterprise Cloud | Public repository under a personal account |
| Copilot | Business or Enterprise seats for both people; the organization enables the Copilot cloud agent (off by default) and Copilot code review | A paid Copilot plan that includes the cloud agent and code review, for both people |
| Code scanning, Copilot Autofix, dependency review | Need GitHub Code Security on the private repository | Free on public repositories |
| Push protection with the "Contoso demo token" custom pattern | Needs GitHub Secret Protection; custom patterns need an organization | Not available (custom patterns need an organization). Skip that optional step |
| Required reviewer on the production environment | GitHub Enterprise for private repositories | Works on public repositories |
| Issue types (`type: feature`) | Yes, in the organization's settings | Not available; the form works without a type |
| CODEOWNERS | A team or users | Users only (the approver) |

Everything else (issues, sub-issues, Projects, rulesets, Actions, environments, OIDC to Azure) works in both options.

### Accounts and tools

- **Azure**: a subscription where you can create a resource group and assign roles in it (Owner, or Contributor plus User Access Administrator).
- **Presenter's laptop**: VS Code with GitHub Copilot Chat and GitHub Pull Requests extensions, Node.js 24, git, and the GitHub CLI (`gh`).
- **Setup scripts**: run them in **Azure Cloud Shell (Bash)**, which already has `az`, `gh`, `git` and `node`, or in any Bash with those tools (Git Bash on Windows works for the GitHub scripts).

---

## 2. One-time setup (about 45 minutes)

### Step 1. Create your demo repository from this template

1. Open <https://github.com/ibranibeny/contoso-order-desk> and select **Use this template → Create a new repository**.
2. Choose the owner (your organization for Option A, your account for Option B) and a name, for example `contoso-order-desk`.
3. Tick **Include all branches**. The fallback branches come with it.
4. Choose the visibility (private for Option A, public for Option B) and select **Create repository**.

Or with the GitHub CLI:

```bash
gh repo create <owner>/contoso-order-desk --template ibranibeny/contoso-order-desk --include-all-branches --public --clone
```

### Step 2. Turn on Copilot for the repository (browser only)

- **Organization (Option A)**: an organization owner opens **Settings → Copilot** and enables the **Copilot cloud agent** policy, gives the demo repository access under **Cloud agent → Repository access**, and enables the **Copilot code review** policy. Enterprise policies can override organization settings.
- **Both options**: confirm that the presenter and the approver each have a Copilot seat or plan that includes the cloud agent and code review.
- Leave the cloud agent's firewall on with the recommended allowlist, and its validation tools (CodeQL, secret scanning, dependency checks) on.

### Step 3. Configure GitHub: `scripts/github-setup.sh`

In Cloud Shell or your terminal, signed in with `gh auth login` as a repository admin:

```bash
git clone https://github.com/<owner>/contoso-order-desk && cd contoso-order-desk
gh auth refresh -s project            # lets the script create the "Order Desk" project
APPROVER=<approver-github-username> scripts/github-setup.sh
```

Organization repositories with issue types and a team: add `ISSUE_TYPE=feature` and `CODEOWNERS_TEAM=@<org>/<team>`.

| The script does | Where you can check it |
|---|---|
| Squash merge only; delete branches after merge | Settings → General |
| Invites the approver with write access (they accept the invitation, then you run the script again) | Settings → Collaborators and teams |
| Creates or reuses the project **Order Desk** and links it | Projects tab |
| Writes `.github/CODEOWNERS` (approver or team) and sets `projects:` (and `type:`) in the feature request form, then commits to main | `.github/` |
| Dependabot alerts and security updates, secret scanning, push protection, CodeQL default setup | Settings → Advanced Security |
| Environment **production**: required reviewer = approver, *Prevent self-review* on, deployments from main only | Settings → Environments |
| Ruleset **Protect main**: pull request with 1 code-owner approval, stale approvals dismissed, conversations resolved, squash only; required checks `build` and `dependency-review`; CodeQL results (high or higher fails); automatic Copilot code review including new pushes; no deletion or force push | Settings → Rules → Rulesets |
| Runs **Copilot Setup Steps** once | Actions tab |
| Tags the starting point `demo-start` | Tags |

If GitHub refuses a rule (for example *Automatically request Copilot code review* on an account without it), the script creates the ruleset without that rule and tells you which one to add in the UI.

### Step 4. Create the Azure side: `scripts/azure-setup.sh`

In **Azure Cloud Shell (Bash)**, in the same clone:

```bash
az account set --subscription <subscription-id>     # if you have several
scripts/azure-setup.sh                              # defaults: southeastasia, B1, Node 24 LTS
```

It creates, in resource group `rg-contoso-order-desk`:

| Resource | Settings | Why |
|---|---|---|
| App Service plan (Linux, B1) and web app (Node.js 24 LTS; falls back to 22 LTS if 24 is not offered) | HTTPS only, TLS 1.2+, FTP off, basic-auth publishing off, Always On, HTTP/2, health check `/health` | Hardening and reliability recommendations from the Well-Architected service guide for App Service |
| Application Insights with a Log Analytics workspace | Auto-instrumentation app settings (Node.js on Linux: public preview) | Operational visibility |
| User-assigned managed identity `id-github-order-desk` | **Website Contributor on the web app only**; federated credential that trusts only the repository's `production` environment | Microsoft Learn recommends OpenID Connect with a user-assigned identity: short-lived tokens, nothing to rotate |

and stores `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` as **environment secrets** of `production` (a job reads them only after the approver approves), plus the repository variable `AZURE_WEBAPP_NAME`. The deploy job is skipped until that variable exists.

> **OIDC subject format.** GitHub Docs: repositories created after 15 July 2026 (and repositories renamed or transferred after that date) use an immutable subject that includes the owner and repository IDs, for example `repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:production`. Older repositories keep `repo:<owner>/<repo>:environment:production`. The script picks the format from the repository's creation date. If the login step fails with `AADSTS70021`, the error message shows the subject GitHub sent; rerun with `SUBJECT_FORMAT=legacy` or `SUBJECT_FORMAT=immutable` to match it. Microsoft Learn pages do not describe the immutable format yet.

**Scope and cost.** This is a demo environment: one B1 instance, public endpoint, no custom domain. The Well-Architected guide recommends Basic tiers for lower environments and removing them when no longer needed; a production Order Desk would add Premium v3 with zone redundancy, private networking, a custom domain and alerts. The B1 plan is billed for every hour it exists, so delete everything after the workshop with `scripts/cleanup-azure.sh`.

### Step 5. First deployment

`azure-setup.sh` starts the **CI/CD** workflow on main. In **Actions**, the run shows `build` passing and `deploy` *Waiting*. The **approver** opens the run, selects **Review deployments**, ticks **production** and selects **Approve and deploy**. When it finishes, open the URL shown on the deploy job: you see the Order Desk placeholder page ("Order lookup is on its way"). That is the "before" picture for the audience.

### Step 6. The few things only the browser can do

- **Project**: open the project, add a **Board** view grouped by Status, and turn on the **Auto-add to project** workflow for this repository (and *Item closed → Done*, which is on by default).
- **Organization only, optional**: custom secret pattern for the push protection demo: **Settings → Advanced Security → Custom patterns → New pattern**, name `Contoso demo token`, secret format `contoso_demo_[a-z0-9]{32}`, save and dry run, publish, then enable push protection for it.
- **If the ruleset was created without the Copilot rule**: edit **Protect main** and add *Automatically request Copilot code review* with *Review new pushes*.

### Step 7. Rehearse twice, and record one rehearsal

Run the whole show (section 4) with the approver. Time each act. Record one full rehearsal as the backup video. If the cloud agent produces a good pull request in rehearsal, label it `keep` and convert it to a draft: `reset-demo.sh` keeps it as a live fallback for Act 3. Then reset (section 5).

---

## 3. Before each demo

| When | Do |
|---|---|
| Day before | `scripts/reset-demo.sh`; redeploy the starting point (**Actions → CI/CD → Run workflow** on main, approver approves); update VS Code and Copilot |
| At least 60 minutes before | `scripts/prepare-security-prs.sh`: opens the two security pull requests so CodeQL and dependency review finish in time |
| 30 minutes before, and again in the break | `scripts/preflight.sh`: checks workflows, ruleset, environment, secrets, last runs, the security pull requests and the web app |
| 15 minutes before | Open the tabs: repository, project board, Actions, Settings → Rules → Rulesets, Security tab, Azure portal (web app), the web app. VS Code: font size 18+, `npm ci` done, terminal open in the repository, Agent and Plan modes visible, notifications off |

---

## 4. Run of show (60 minutes)

The ten chapters match the replay. Each step lists what to **do**, what to **type**, what to **expect**, what to **say**, and the **fallback**. Issue and pull request numbers below (#12–#15) are the replay's; yours will be different, so use the numbers GitHub shows you.

| Replay chapter | Act and minutes | Who drives |
|---|---|---|
| Set the scene | 0–3 | Presenter |
| 1. Issues & Projects | Act 1 · 3–10 | Presenter |
| 2. GitHub Copilot (VS Code) | Act 2 · 10–24 | Presenter |
| 3. Pull requests | Act 3 · 24–32 | Presenter + Approver |
| 4. Security gates | Act 4 · 32–44 | Presenter |
| 5. Ruleset · 6. Actions · 7. Environment · 8. Azure · 9. Live app | Act 5 · 44–54 | Presenter + Approver |
| 10. Close the loop | Act 6 · 54–60 | Presenter |

### Set the scene (0–3 min)

- **Do:** show the live web app (placeholder page) and the repository: a small Node.js 24 + Express 5 app with synthetic order data.
- **Say:** read the business requirement aloud (it is in [PROMPTS.md](PROMPTS.md#0-business-requirement)). Introduce the approver: "two people, because the platform will not let one person approve their own work."

### Chapter 1 · Issues & Projects (3–10 min)

1. **Do:** open <https://github.com/copilot> (Copilot Chat on GitHub.com).
   **Type:** [prompt 1](PROMPTS.md#1-create-the-issue-with-copilot) with the requirement pasted in.
   **Expect:** a draft feature issue that follows the *Feature request* form, plus three draft sub-issues: API, agent page, audit log.
2. **Do:** read the acceptance criteria aloud and change one by hand before you select **Create**.
   **Say:** "People own the requirement. Copilot drafted it; I decide what it says."
3. **Do:** open the **Order Desk** project board. The issue arrived through the form's `projects:` key or the auto-add workflow. Organization: set the issue type to **Feature**. Move it to **In progress**.
4. **Do:** open sub-issue **Agent lookup page (#14)** → **Assignees → Copilot**, paste the [optional prompt](PROMPTS.md#2-assign-the-page-to-copilot) and assign.
   **Expect:** an 👀 reaction, then a draft pull request in the issue timeline and a "Copilot started work" event with **View session**.
   **Say:** "The issue is the contract. Copilot reads what is in the issue when I assign it, so later comments go on the pull request."

**If it fails:** creating issues with Copilot is in public preview. Use **New issue → Feature request** and paste the prepared text, or run `scripts/create-demo-issues.sh` before you go on stage. The rest of the demo is unchanged.

### Chapter 2 · GitHub Copilot in VS Code (10–24 min)

1. **Do:** in VS Code, create the branch `feature/order-lookup-api`. Open `.github/copilot-instructions.md` for ten seconds.
   **Say:** "These are Contoso's rules: Node 24, Express 5, tests with `node --test`, validate every parameter, never return payment or contact data. Every Copilot surface reads them."
2. **Do:** in Copilot Chat choose **Plan**.
   **Type:** [prompt 3](PROMPTS.md#3-plan-mode-in-vs-code).
   **Expect:** a plan that names the files (for example `src/orders.js` or `src/validation.js`, `src/app.js`, `test/orders.test.js`) and the test cases. No files change yet.
3. **Do:** switch to **Agent**.
   **Type:** [prompt 4](PROMPTS.md#4-agent-mode-in-vs-code).
   **Expect:** edits across files, then a request to run `npm test` in the terminal. Select **Allow**. Tests pass, or the agent fixes them and runs them again.
4. **Do:** review the diff like a senior engineer: the order number regular expression (`^ORD-\d{6}$`), the 404 body, and that the response is an allow-list of `id`, `status`, `lastUpdated`, `estimatedDelivery`. Change one small thing by hand.
5. **Do:** in Source Control, use **Generate commit message**, commit and push. Create the pull request (GitHub Pull Requests extension or `gh pr create`), let Copilot write the description, and make sure it contains `Fixes #13`.
   **Say:** "Agent mode did the typing and ran the test loop. I chose the design, approved every command and reviewed the diff."

**If it fails** (the agent stalls, or tests still fail after two rounds): stop, and say "this is the rehearsal run of the same prompt". Then:

```bash
git switch fallback/order-lookup-api
gh pr create --base main --head fallback/order-lookup-api --title "Add order lookup API" --body "Fixes #13"
```

Keep the clock visible: if you are more than 3 minutes behind at minute 24, use the fallback.

### Chapter 3 · Pull requests (24–32 min)

1. **Do:** open the API pull request. The ruleset requested Copilot as a reviewer automatically (otherwise **Reviewers → Copilot**).
   **Expect:** a review from Copilot with comments, usually within a minute. It is a *Comment* review and does not count toward the required approval.
   **Do:** read one comment aloud and apply a suggestion with **Commit suggestion**, or ask for a change with a reply. Resolve the conversation (the ruleset requires resolved conversations).
2. **Do:** open the cloud agent's pull request (linked from issue #14) and select **View session**: the agent's plan, the commands it ran, its tests and its self-checks.
3. **Approver:** on the pull request, select **Approve and run workflows** so the checks start.
4. **Do:** comment on the cloud agent's pull request.
   **Type:** [prompt 5](PROMPTS.md#5-iterate-on-copilots-pull-request).
   **Expect:** Copilot reacts, works, and pushes a new commit to the same pull request.
5. **Approver:** after Copilot's last push, review and **Approve** both pull requests (the code owner review is required). Approving earlier would be dismissed by a new push.
   **Say:** "Copilot gives a fast first review, but merging still needs a different human's approval. That is enforced by the platform, not by good intentions."

**If it fails:** if the cloud agent's pull request is not ready, show the live session log, then open the `keep` draft pull request from rehearsal, or open one from the fallback branch:

```bash
gh pr create --base main --head fallback/agent-lookup-page --title "Add the agent order lookup page" --body "Fixes #14"
```

Come back to the live pull request at the end if it finishes.

### Chapter 4 · Security gates (32–44 min)

1. **Do:** open the pull request **Show a not-found message for order lookups** (`demo/not-found-message`, opened before the session).
   **Expect:** the *CodeQL* check fails with a cross-site scripting alert on the changed line, and a **Copilot Autofix** suggestion (typically, encoding the output).
2. **Do:** review the Autofix patch and commit it to the branch. Wait for the rerun: the alert closes.
   **Say:** "Security feedback arrives in the pull request, with a proposed fix, before anything merges. The same gates apply to code written by Copilot."
3. **Do:** open the pull request **Add a date helper for delivery windows** (`demo/add-date-helper`).
   **Expect:** the *Dependency Review* check fails and lists the advisories for `lodash@4.17.15`; the action also posts a summary comment. **Files changed** shows the dependency diff.
4. **Do:** scroll to the merge box: merging is blocked until required checks pass and conversations are resolved. **Close** the dependency pull request.
5. **Optional** (organization with the custom pattern, and only if not shown in Session 4): push protection.

```bash
scripts/push-protection-demo.sh
```

   **Expect:** the push is rejected, naming the secret type, file and line. Do not bypass.

**If it fails:** if CodeQL is still running, show the alert on the Security tab or the rehearsal screenshots, and come back. Confirm in rehearsal that this alert fails the check and gets an Autofix suggestion at your thresholds; Copilot Autofix covers a subset of CodeQL queries on a best-effort basis.

### Chapters 5–9 · Ruleset, Actions, Environment, Azure, Live app (44–54 min)

1. **Ruleset (chapter 5):** open **Settings → Rules → Rulesets → Protect main** for twenty seconds: required review from code owners, required checks, CodeQL results, automatic Copilot review, no force push.
   **Do:** **Squash and merge** the API pull request, then the page pull request. `Fixes #13` and `Fixes #14` close the sub-issues.
2. **Actions (chapter 6):** open **Actions → CI/CD** on main: `build` passes, then `deploy` shows *Waiting* for the production environment. If you merged both pull requests within a minute, the first run's `deploy` is cancelled on purpose (one deployment at a time); the newer run deploys both changes with a single approval.
3. **Environment production (chapter 7):** the **approver** selects **Review deployments → production → Approve and deploy**. With *Prevent self-review* on, the presenter could not approve it.
4. **Azure (chapter 8):** open the deploy job's log. The **Az CLI login (OIDC, no stored password)** step signs in with a short-lived token.
   **Say:** "Azure trusts a short-lived token from this repository's production environment, and nothing else. The identity can deploy to this one web app only. A person approved the release, and GitHub recorded it."
   Optionally show the managed identity's **Federated credentials** and its **Website Contributor** role assignment in the Azure portal.
5. **Live app (chapter 9):** open the URL on the deploy job, then look up:
   - `ORD-100232` → *Out for delivery*, estimated delivery, the tracker
   - `ORD-999999` → "We couldn't find ORD-999999"
   - `12345` → "Check the order number: Order numbers look like ORD-123456"
   Then show **Deployments** on the repository home page: each release with its environment, commit and logs.

**If it fails:** if login or deploy is red, show the last successful deployment and the live site, and fix the credential afterwards (see Troubleshooting). If the network fails, play the rehearsal recording, or the simulated replay, and say that it is a recording.

### Chapter 10 · Close the loop (54–60 min)

1. **Do:** back on the project board, the API and page items are **Done**; the stakeholder sees the outcome without reading code.
2. **Say:** the hour in one line: requirement → issue (Copilot) → API (agent mode) and page (cloud agent) in parallel → Copilot and human review → CodeQL with Autofix and dependency review → CI/CD with approval and OIDC → live.
3. **Do:** show the audit trail: signed commits linked to the agent's session, the required reviews, the deployment approval.
4. **Say:** "Sub-issue #15, the audit log, is still open. In the next session we will see what it means to hand whole workstreams like that to agents."

---

## 5. After the demo

- **Reset for the next run:** `scripts/reset-demo.sh` closes pull requests and issues (except those labelled `keep`), deletes demo-time branches, and moves main back to `demo-start` (it pauses the ruleset for a moment). Then redeploy the starting point and run `scripts/prepare-security-prs.sh` again before the next session.
- **After the workshop:** `scripts/cleanup-azure.sh` deletes the resource group and removes the Azure secrets and variable from the repository. Remove the custom secret pattern if you created it at organization level. Archive the repository or keep it for the next workshop.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Copilot does not appear under **Assignees** | Cloud agent not enabled for the repository, or no eligible seat | Section 2, step 2. Check the organization's Copilot policies and repository access |
| Checks never start on Copilot's pull request | Workflows on Copilot's pull requests need approval | The approver selects **Approve and run workflows** |
| You cannot approve Copilot's pull request | You requested the work | By design: the approver approves |
| Merge blocked: "Review required" after approval | A new push dismissed the approval (*dismiss stale approvals*) | Approve again after the last push |
| Merge blocked: "Conversations must be resolved" | Open review threads (including Copilot's) | Resolve each conversation |
| Required check `build` or `dependency-review` "expected" but never runs | The workflow file is missing on the branch, or the check name changed | The jobs must be called `build` and `dependency-review`; branch from current main |
| CodeQL check passes on `demo/not-found-message` | Analysis not finished, or thresholds differ | Wait for **Code scanning results**; in the ruleset, set *Security alerts* to *High or higher* and *Alerts* to *Errors* |
| Dependency review passes on `demo/add-date-helper` | Dependency graph off, or the advisory data changed | Turn on the dependency graph; check the advisories for `lodash@4.17.15` on the GitHub Advisory Database |
| Deploy job skipped | `AZURE_WEBAPP_NAME` variable not set | Run `scripts/azure-setup.sh` |
| Deploy waits for ever | Nobody approved it | The approver selects **Review deployments** |
| Login fails with `AADSTS70021: No matching federated identity record` | Subject mismatch | Read the subject in the error; rerun `azure-setup.sh` with `SUBJECT_FORMAT=legacy` or `immutable` |
| Login fails with an authorization error during deploy | Role assignment still replicating, or missing | Wait two minutes and re-run the job; check **Website Contributor** on the web app |
| Smoke test fails after deploy | App still starting | Re-run the job; check **Log stream** for the web app in the Azure portal |
| `github-setup.sh` cannot add the approver to the environment | Invitation not yet accepted, or required reviewers not available for a private repository on your plan | Accept the invitation and rerun; see the plan table in section 1 |

---

## 7. What has been tested, and what you must check in rehearsal

**Tested before publishing this repository**

- The app and its tests: `npm ci && npm test` on a GitHub-hosted runner with Node.js 24 and Express 5, for `main`, `fallback/order-lookup-api`, `fallback/agent-lookup-page`, `solution` and both demo branches.
- The finished app (`solution` branch) was started and the screenshots in the README were taken from it.
- The setup scripts were run end to end against stand-in `gh` and `az` commands (to check the script logic), not against real GitHub and Azure accounts.

**Not tested here, so check it in your first rehearsal**

- `github-setup.sh` and `azure-setup.sh` against your real organization, plan and subscription. In particular, the ruleset rule `copilot_code_review` and the `allowed_merge_methods` setting: the script falls back without them if GitHub refuses them.
- Copilot's live behaviour in your organization: creating issues (public preview), the cloud agent, Copilot code review and Copilot Autofix results.
- That the CodeQL alert fails the check at your thresholds and gets an Autofix suggestion, and that dependency review still flags `lodash@4.17.15`.
- The first deployment to Azure with your subscription's policies (some tenants restrict managed identities, role assignments or basic-auth settings).

---

## 8. References

GitHub Docs

- [Using GitHub Copilot to create or update issues](https://docs.github.com/en/copilot/how-tos/copilot-on-github/copilot-for-github-tasks/use-copilot-to-create-or-update-issues) · [Syntax for issue forms](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms) · [Adding sub-issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues)
- [Using Copilot cloud agent on GitHub](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-github) · [Adding the cloud agent to your organization](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-organization/add-copilot-cloud-agent) · [Customize the agent environment](https://docs.github.com/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/customize-the-agent-environment)
- [Use agent mode](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/use-copilot-agents/use-agent-mode) · [Use plan mode](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/use-copilot-agents/use-plan-mode) · [Repository custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/customize-copilot/configure-custom-instructions/add-repository-instructions-in-your-ide)
- [Configure Copilot code review](https://docs.github.com/en/copilot/how-tos/copilot-on-github/set-up-copilot/configure-code-review) · [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) · [About code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [Triage code scanning alerts in pull requests](https://docs.github.com/en/code-security/how-tos/manage-security-alerts/manage-code-scanning-alerts/triage-alerts-in-pull-requests) · [Autofix for code scanning](https://docs.github.com/en/code-security/concepts/code-scanning/autofix-for-code-scanning) · [Set code scanning merge protection](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/set-merge-protection)
- [Dependency review](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependency-review) · [Configure the dependency review action](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/manage-your-dependency-security/configure-dependency-review-action)
- [Push protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection) · [Define custom patterns](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/customize-leak-detection/define-custom-patterns)
- [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) · [Viewing deployment history](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/view-deployment-history) · [Deploying Node.js to Azure App Service](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/nodejs-to-azure-app-service)
- [Configuring OpenID Connect in Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure) · [OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc) (subject claims, including the immutable format)

Microsoft Learn

- [Deploy to Azure App Service by using GitHub Actions](https://learn.microsoft.com/en-us/azure/app-service/deploy-github-actions) (OpenID Connect, user-assigned identity, Website Contributor scoped to the app)
- [Authenticate to Azure from GitHub Actions by OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) (user-assigned managed identity option; environment secrets for public repositories)
- [Create a trust relationship between an app and an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust)
- [Disable basic authentication in App Service deployments](https://learn.microsoft.com/en-us/azure/app-service/configure-basic-auth-disable)
- [Monitor Azure App Service](https://learn.microsoft.com/en-us/azure/app-service/monitor-app-service) (Application Insights auto-instrumentation for Node.js on Linux, public preview)
- [Architecture best practices for Azure App Service (Well-Architected Framework)](https://learn.microsoft.com/en-us/azure/well-architected/service-guides/app-service-web-apps)
