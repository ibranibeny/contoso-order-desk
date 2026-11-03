#!/usr/bin/env bash
# Data collection for the Daily SDLC Health agentic workflow (.github/workflows/daily-sdlc-health.md).
# It only reads: builds on the default branch, open pull requests, GitHub Advanced Security alerts and the
# issues the workflow raised before. It writes compact JSON for the agent to $SDLC_OUT:
#   summary.json   needs_fixing, report_title, counts and the status of each source
#   findings.json  everything that needs fixing, most severe first, with tracking information
#   to_close.json  earlier reports, and fix issues whose problem is gone
# Environment: GH_TOKEN and GITHUB_REPOSITORY. Optional: SECRET_SCANNING_TOKEN (a token that can read secret
# scanning alerts), SDLC_OUT (default /tmp/gh-aw/agent/sdlc), GITHUB_SERVER_URL and GITHUB_RUN_ID.
set -euo pipefail

repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
server=${GITHUB_SERVER_URL:-https://github.com}
api=${GITHUB_API_URL:-https://api.github.com}
out=${SDLC_OUT:-/tmp/gh-aw/agent/sdlc}
raw="$out/raw"
rm -rf "$out"
mkdir -p "$raw"

now=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
checked_at=$(iso "$now")
branch=$(gh api "repos/$repo" --jq .default_branch)
self=daily-sdlc-health # this workflow's own runs are never findings

# Status of each source: ok, not_enabled, not_checked or unavailable.
declare -A status=([build]=ok [code_review]=ok [code_scanning]=ok [dependabot]=ok [secret_scanning]=ok [tracking]=ok)
for f in prs code_scanning analyses dependabot secret_scanning pending_waiting pending_action_required open_issues closed_issues; do
  echo '[]' > "$raw/$f.json"
done
: > "$raw/build_runs.ndjson"
: > "$raw/failing_details.ndjson"

# fetch NAME JQ_FILTER GH_API_ARGS...: writes raw/NAME.json, the JSON array of the filter's results.
# On failure it writes [] and returns 1, and the error stays in raw/NAME.err.
fetch() {
  local name=$1 filter=$2
  shift 2
  if gh api "$@" --jq "$filter" > "$raw/$name.ndjson" 2> "$raw/$name.err"; then
    jq -s '.' "$raw/$name.ndjson" > "$raw/$name.json"
  else
    echo '[]' > "$raw/$name.json"
    return 1
  fi
}
# failed SOURCE NAME: marks a security source not_enabled (HTTP 404, or the feature is off) or unavailable.
failed() {
  if grep -qiE 'HTTP 404|disabled' "$raw/$2.err"; then status[$1]=not_enabled; else status[$1]=unavailable; fi
  echo "::warning::$1: $(tr '\n' ' ' < "$raw/$2.err" | cut -c1-300)"
}
# excerpt LOG: the lines leading to the first error and any further errors, or else the last 60 lines,
# without timestamps and colour codes.
excerpt() {
  local first
  first=$(grep -n -m1 '##\[error\]' "$1" | cut -d: -f1 || true)
  if [ -n "$first" ]; then
    sed -n "$((first > 40 ? first - 40 : 1)),$((first + 5))p" "$1"
    grep '##\[error\]' "$1" | sed -n '2,10p'
  else
    tail -n 60 "$1"
  fi | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //; s/\x1b\[[0-9;]*[A-Za-z]//g' | cut -c1-300
}

# --- Build: the latest completed runs, on the default branch, of every workflow that still exists.
if fetch workflow_files '.[] | {path}' -X GET "repos/$repo/contents/.github/workflows" -f ref="$branch" &&
  fetch workflows '.workflows[] | select(.state == "active") | {id, name, path}' -X GET "repos/$repo/actions/workflows" -f per_page=100; then
  while read -r wf; do
    id=$(jq -r .id <<< "$wf")
    if fetch "runs_$id" '.workflow_runs[] | {id, event, conclusion, created_at, url: .html_url, head_repository: .head_repository.full_name}' \
      -X GET "repos/$repo/actions/workflows/$id/runs" -f branch="$branch" -f status=completed -f per_page=100; then
      # The branch filter also matches pull requests whose head is a branch of that name, such as a fork's main.
      jq -c --argjson wf "$wf" --arg repo "$repo" '{workflow: $wf.name, path: $wf.path,
          runs: map(select(.head_repository == $repo and (.event | IN("pull_request", "pull_request_target") | not))
            | del(.head_repository))}' "$raw/runs_$id.json" >> "$raw/build_runs.ndjson"
    else
      status[build]=unavailable
    fi
  done < <(jq -c --slurpfile files "$raw/workflow_files.json" --arg self "$self" '.[]
    | select((.path | startswith("dynamic/")) or (.path as $p | any($files[0][]; .path == $p)))
    | select(.path | contains($self) | not)' "$raw/workflows.json")
else
  status[build]=unavailable
fi

# A workflow fails when its latest decisive run failed. The failure streak goes back to the last success.
jq -s -c '.[]
  | .runs |= map(select(.conclusion | IN("success", "failure", "timed_out", "startup_failure")))
  | select((.runs | length) > 0 and .runs[0].conclusion != "success")
  | (.runs | map(.conclusion == "success") | index(true)) as $ok
  | .runs[0:($ok // (.runs | length))] as $streak
  | {workflow, path, latest_run: $streak[0], since: $streak[-1].created_at, since_is_approximate: ($ok == null),
     failed_runs: ($streak | length)}' "$raw/build_runs.ndjson" > "$raw/failing.ndjson"

while read -r failing; do
  run=$(jq -r .latest_run.id <<< "$failing")
  jobs='[]'
  if fetch "jobs_$run" '.jobs[] | select(.conclusion | IN("failure", "timed_out")) | {id, name, conclusion, url: .html_url,
      failed_steps: [.steps[]? | select(.conclusion | IN("failure", "timed_out")) | .name]}' \
    -X GET "repos/$repo/actions/runs/$run/jobs" -f filter=latest; then
    # Log excerpts of the first two failed jobs. gh refuses log output with colour codes, so curl fetches the logs.
    while read -r job; do
      id=$(jq -r .id <<< "$job")
      if [ "$(jq -r .n <<< "$job")" -lt 2 ] &&
        curl -sSfL --max-time 60 -H "Authorization: Bearer ${GH_TOKEN:-}" -H "Accept: application/vnd.github+json" \
          "$api/repos/$repo/actions/jobs/$id/logs" -o "$raw/log_$id.txt" 2> /dev/null; then
        excerpt "$raw/log_$id.txt" > "$raw/excerpt_$id.txt"
        jq -c --rawfile log "$raw/excerpt_$id.txt" 'del(.n) + {log_excerpt: $log}' <<< "$job"
      else
        jq -c 'del(.n) + {log_excerpt: null}' <<< "$job"
      fi
    done < <(jq -c 'to_entries[] | .value + {n: .key}' "$raw/jobs_$run.json") > "$raw/job_details_$run.ndjson"
    jobs=$(jq -s -c '.' "$raw/job_details_$run.ndjson")
  fi
  jq -c --argjson jobs "$jobs" '. + {jobs: $jobs}' <<< "$failing" >> "$raw/failing_details.ndjson"
done < "$raw/failing.ndjson"
jq -s '.' "$raw/failing_details.ndjson" > "$raw/failing_details.json"

# Runs waiting for an approval: an environment reviewer, or a workflow run that needs approving.
for s in waiting action_required; do
  fetch "pending_$s" '.workflow_runs[] | {id, workflow: .name, path, event, branch: .head_branch, status, conclusion, created_at, url: .html_url}' \
    -X GET "repos/$repo/actions/runs" -f status="$s" -f per_page=50 || status[build]=unavailable
done

# --- Code review: open pull requests.
# shellcheck disable=SC2016 # $owner and $name are GraphQL variables
pr_query='query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 50, orderBy: {field: CREATED_AT, direction: ASC}) {
      nodes {
        number title url isDraft createdAt updatedAt reviewDecision mergeable
        author { login }
        latestReviews(first: 20) { nodes { state author { __typename login } } }
        reviewThreads(first: 100) { nodes { isResolved } }
        commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { name conclusion }
          ... on StatusContext { context state }
        } } } } } }
      }
    }
  }
}'
fetch prs '.data.repository.pullRequests.nodes[]' graphql -f query="$pr_query" -f owner="${repo%/*}" -f name="${repo#*/}" ||
  status[code_review]=unavailable

# --- GitHub Advanced Security.
fetch code_scanning '.[] | {number, rule: .rule.id, description: .rule.description, severity: (.rule.security_severity_level // .rule.severity),
    tool: .tool.name, path: .most_recent_instance.location.path, line: .most_recent_instance.location.start_line,
    message: .most_recent_instance.message.text, created_at, url: .html_url}' \
  --paginate -X GET "repos/$repo/code-scanning/alerts" -f state=open -f per_page=100 || failed code_scanning code_scanning
if [ "${status[code_scanning]}" = ok ]; then
  fetch analyses '.[] | {category, created_at}' -X GET "repos/$repo/code-scanning/analyses" -f ref="refs/heads/$branch" -f per_page=20 ||
    failed code_scanning analyses
fi
fetch dependabot '.[] | {number, package: .dependency.package.name, ecosystem: .dependency.package.ecosystem, manifest: .dependency.manifest_path,
    severity: .security_advisory.severity, ghsa: .security_advisory.ghsa_id, cve: .security_advisory.cve_id, summary: .security_advisory.summary,
    vulnerable_range: .security_vulnerability.vulnerable_version_range, patched: .security_vulnerability.first_patched_version.identifier,
    created_at, url: .html_url}' \
  --paginate -X GET "repos/$repo/dependabot/alerts" -f state=open -f per_page=100 || failed dependabot dependabot
if [ -n "${SECRET_SCANNING_TOKEN:-}" ]; then
  # hide_secret keeps secret values out of the response, and the filter keeps them out of the files.
  GH_TOKEN=$SECRET_SCANNING_TOKEN fetch secret_scanning '.[] | {number, type: .secret_type_display_name, created_at, push_protection_bypassed,
      validity, url: .html_url}' \
    --paginate -X GET "repos/$repo/secret-scanning/alerts" -f state=open -f hide_secret=true -f per_page=100 ||
    failed secret_scanning secret_scanning
else
  status[secret_scanning]=not_checked
fi

# --- Issues this workflow raised before. A fix issue's body ends with "Finding key: `<key>`".
# All open ones, page by page: without them a problem could be raised twice, so a failed read stops new fix issues.
# shellcheck disable=SC2016 # $owner, $name, $endCursor and $q are GraphQL variables
open_query='query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, labels: ["agentic-sdlc"], first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url body
        labels(first: 20) { nodes { name } }
        closedByPullRequestsReferences(first: 5, includeClosedPrs: false) { nodes { number url isDraft author { login } } }
      }
    }
  }
}'
fetch open_issues '.data.repository.issues.nodes[]' graphql --paginate -f query="$open_query" -f owner="${repo%/*}" -f name="${repo#*/}" || {
  status[tracking]=unavailable
  echo "::warning::tracking: $(tr '\n' ' ' < "$raw/open_issues.err" | cut -c1-300)"
}
# The latest closed fix issues, without the daily reports, to link a problem that comes back to its earlier issue.
# shellcheck disable=SC2016
closed_query='query($q: String!) { search(query: $q, type: ISSUE, first: 100) { nodes { ... on Issue { number url body closedAt } } } }'
fetch closed_issues '.data.search.nodes[]' graphql -f query="$closed_query" \
  -f q="repo:$repo is:issue is:closed label:agentic-sdlc -label:report sort:updated-desc" ||
  echo "::warning::closed fix issues: $(tr '\n' ' ' < "$raw/closed_issues.err" | cut -c1-300)"

# --- Findings, tracking and what to close.
status_json=$(for k in "${!status[@]}"; do printf '%s\t%s\n' "$k" "${status[$k]}"; done |
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add')

jq -n --arg branch "$branch" --arg base "$server/$repo" --arg self "$self" --argjson now "$now" --argjson status "$status_json" \
  --slurpfile failing "$raw/failing_details.json" --slurpfile waiting "$raw/pending_waiting.json" \
  --slurpfile action_required "$raw/pending_action_required.json" --slurpfile prs "$raw/prs.json" \
  --slurpfile cs "$raw/code_scanning.json" --slurpfile analyses "$raw/analyses.json" --slurpfile dep "$raw/dependabot.json" \
  --slurpfile ss "$raw/secret_scanning.json" --slurpfile open_issues "$raw/open_issues.json" \
  --slurpfile closed_issues "$raw/closed_issues.json" '
  def hours(t): ($now - (t | fromdateiso8601)) / 3600 | floor;
  def days(t): ($now - (t | fromdateiso8601)) / 86400 | floor;
  def rank: {"critical": 0, "high": 1, "error": 1, "medium": 2, "moderate": 2, "warning": 2, "low": 3, "note": 3}[.] // 4;
  def key_of: (first((.body // "") | capture("Finding key: `(?<k>[^`]+)`")) | .k) // null;
  # Keys use "/" and a small character set: the safe-output sanitizer redacts text such as "data:..." and escapes @mentions.
  def safe_key: gsub("[^A-Za-z0-9._/-]"; "_");
  def source_of: if startswith("build/") then "build" elif startswith("code-scanning/") then "code_scanning"
    elif startswith("dependabot/") then "dependabot" elif startswith("secret-scanning/") then "secret_scanning" else null end;

  [$open_issues[0][] | {number, url, title, key: key_of, labels: [.labels.nodes[].name],
      fix_prs: [.closedByPullRequestsReferences.nodes[] | {number, url, draft: .isDraft, author: (.author.login // null)}]}] as $open
  | [$closed_issues[0][] | {number, url, key: key_of, closed_at: .closedAt}] as $closed
  | $prs[0] as $pulls
  | [
      ($failing[0][] | {
        key: ("build/\(.path)" | safe_key), area: "build", label: "build", severity: "high", fix_issue: true,
        issue_title: "Build failing on \($branch): \(.workflow) (since \(.since[0:10]))",
        summary: "\(.workflow) fails on \($branch) since \(.since) (\(.failed_runs) failed run(s) in a row)",
        url: .latest_run.url, details: .}),

      (($waiting[0] + $action_required[0]) | unique_by(.id)[]
        | select((.path // "") | contains($self) | not) | select(hours(.created_at) >= 1) | {
        key: "approval/\(.id)", area: "build", severity: "medium", fix_issue: false,
        summary: "\(.workflow) on \(.branch) has waited \(hours(.created_at)) hour(s) for an approval",
        url, details: .}),

      ($pulls[] | select(.isDraft | not)
        | ([.reviewThreads.nodes[] | select(.isResolved | not)] | length) as $unresolved
        | ([.latestReviews.nodes[] | select(.author.__typename == "User")] | length) as $people
        | ([.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
            | select((.conclusion // .state // "") | IN("FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR"))
            | (.name // .context)] | unique) as $failing_checks
        | [(if $unresolved > 0 then "\($unresolved) unresolved review thread(s)" else empty end),
           (if .reviewDecision == "CHANGES_REQUESTED" then "changes requested" else empty end),
           (if ($failing_checks | length) > 0 then "failing checks: \($failing_checks | join(", "))" else empty end),
           (if .mergeable == "CONFLICTING" then "merge conflicts" else empty end),
           (if hours(.createdAt) >= 24 and .reviewDecision != "APPROVED" and $people == 0
             then "waiting \(days(.createdAt)) day(s) for a review" else empty end),
           (if days(.updatedAt) >= 7 then "no activity for \(days(.updatedAt)) days" else empty end)] as $reasons
        | select($reasons | length > 0) | {
        key: "pr/\(.number)", area: "code-review", fix_issue: false,
        severity: (if ($failing_checks | length) > 0 or .mergeable == "CONFLICTING" then "medium" else "low" end),
        summary: "Pull request \(.number) by \(.author.login // "ghost"): \($reasons | join("; "))",
        url, details: {number, title, author: (.author.login // null), created_at: .createdAt, updated_at: .updatedAt,
          review_decision: .reviewDecision, reasons: $reasons}}),

      ($cs[0][] | {
        key: "code-scanning/\(.number)", area: "security", label: "security", severity: (.severity // "warning"), fix_issue: true,
        issue_title: "Code scanning alert \(.number): \(.rule) in \(.path)",
        summary: "\(.tool) alert \(.number) (\(.severity)): \(.description) at \(.path):\(.line)",
        url, details: .}),

      (($analyses[0] | map(.created_at) | max) as $last
        | select($status.code_scanning == "ok" and $last != null and days($last) >= 8) | {
        key: "code-scanning-stale", area: "security", severity: "medium", fix_issue: false,
        summary: "Code scanning last analysed \($branch) \(days($last)) days ago",
        url: "\($base)/security/code-scanning", details: {last_analysis: $last}}),

      ($dep[0] | group_by([.ecosystem, .package, .manifest])[] | sort_by(.severity | rank) | .[0] as $top | {
        key: ("dependabot/\($top.ecosystem)/\($top.package)/\($top.manifest)" | safe_key), area: "dependencies", label: "dependencies",
        severity: $top.severity, fix_issue: true,
        issue_title: "Vulnerable dependency: \($top.package) (\($top.ecosystem)) in \($top.manifest)",
        summary: "\(length) open Dependabot alert(s) for \($top.package) in \($top.manifest), highest severity \($top.severity)",
        url: $top.url, details: {package: $top.package, ecosystem: $top.ecosystem, manifest: $top.manifest, alerts: .,
          dependabot_pull_requests: [$pulls[] | select((.author.login // "") | test("dependabot"))
            | select(.title | contains($top.package)) | {number, url, title}]}}),

      ($ss[0][] | {
        key: "secret-scanning/\(.number)", area: "secret-scanning", label: "secret-scanning", severity: "critical", fix_issue: true,
        issue_title: "Leaked secret: \(.type) (secret scanning alert \(.number))",
        summary: "Secret scanning alert \(.number): \(.type), found \(.created_at[0:10])\(if .push_protection_bypassed then ", pushed past push protection" else "" end)",
        url, details: .})
    ]
  | map(. as $f | . + (if .fix_issue and $status.tracking == "ok" then
      {tracked_by: (first($open[] | select(.key == $f.key) | {number, url, fix_prs}) // null),
       previously_closed: (first($closed[] | select(.key == $f.key) | {number, url, closed_at}) // null)}
      else {fix_issue: false, tracked_by: null, previously_closed: null} end))
  | sort_by((.severity | rank), .area, .key)
  | ([.[] | select(.fix_issue and .tracked_by == null) | .key][0:5]) as $raise
  | map(.raise_issue = (.key as $k | any($raise[]; . == $k)))
  | . as $findings
  | {findings: $findings,
     to_close: (if $status.tracking != "ok" then {reports: [], resolved: []} else {
       reports: [$open[] | select(any(.labels[]; . == "report")) | {number, url, title}],
       resolved: [$open[] | select(any(.labels[]; . == "report") | not) | select(.key != null)
         | select(.key as $k | all($findings[]; .key != $k))
         | select((.key | source_of) as $s | $s != null and $status[$s] == "ok")
         | {number, url, title, key}]} end)}' > "$raw/result.json"

jq '.findings' "$raw/result.json" > "$out/findings.json"
jq '.to_close' "$raw/result.json" > "$out/to_close.json"
jq -n --slurpfile result "$raw/result.json" --argjson status "$status_json" --arg repo "$repo" --arg branch "$branch" \
  --arg checked_at "$checked_at" --arg run_url "$server/$repo/actions/runs/${GITHUB_RUN_ID:-0}" '
  $result[0] as $r | $r.findings as $f
  | def count(cond): [$f[] | select(cond)] | length;
  {
    repository: $repo,
    default_branch: $branch,
    checked_at: $checked_at,
    run_url: $run_url,
    report_title: "SDLC health report, \($checked_at[0:10]) \($checked_at[11:16]) UTC",
    sources: $status,
    needs_fixing: (($f | length) > 0 or any($status[]; . == "unavailable")),
    counts: {
      failing_workflows: count(.key | startswith("build/")),
      runs_waiting_for_approval: count(.key | startswith("approval/")),
      pull_requests_needing_attention: count(.area == "code-review"),
      code_scanning_alerts: count(.key | startswith("code-scanning/")),
      dependabot_alerts: ([$f[] | select(.area == "dependencies") | .details.alerts | length] | add // 0),
      secret_scanning_alerts: count(.area == "secret-scanning")
    },
    fix_issues: {
      to_raise: count(.raise_issue),
      already_open: count(.tracked_by != null),
      left_for_next_run: count(.fix_issue and .tracked_by == null and (.raise_issue | not))
    },
    to_close: {reports: ($r.to_close.reports | length), resolved: ($r.to_close.resolved | length)}
  }' > "$out/summary.json"

rm -rf "$raw"
cat "$out/summary.json"
