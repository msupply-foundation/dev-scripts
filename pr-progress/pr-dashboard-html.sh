#!/usr/bin/env bash
set -euo pipefail

# PR Dashboard — generates a static HTML page
# Usage: ./scripts/pr-dashboard-html.sh <label> [output.html]
# Example: ./scripts/pr-dashboard-html.sh "Team Ruru 🦉" pr-dashboard.html

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <label> [output.html]"
  echo "Example: $0 \"bug\" dashboard.html"
  exit 1
fi

LABEL="$1"
OUTPUT="${2:-pr-dashboard.html}"

# Cross-platform date parsing (macOS + Linux) → epoch
parse_date() {
  local iso="$1"
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null; then
    return
  fi
  date -d "$iso" +%s 2>/dev/null
}

now=$(date +%s)
generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Fetching PRs with label \"$LABEL\"..."

prs_json=$(gh pr list \
  --label "$LABEL" \
  --state open \
  --json number,title,author,assignees,updatedAt,createdAt,url,reviewDecision \
  --limit 100)

count=$(echo "$prs_json" | jq 'length')

if [[ "$count" -eq 0 ]]; then
  echo "No open PRs found with label \"$LABEL\"."
  exit 0
fi

echo "Found ${count} PR(s). Fetching activity data..."

# Build a JSON array with enriched PR data
enriched="[]"

echo "$prs_json" | jq -c '.[]' | while read -r pr; do
  number=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')
  author=$(echo "$pr" | jq -r '.author.login')
  url=$(echo "$pr" | jq -r '.url')
  created_at=$(echo "$pr" | jq -r '.createdAt')
  review_decision=$(echo "$pr" | jq -r '.reviewDecision // empty')

  if [[ -z "$review_decision" ]]; then
    review_decision="REVIEW_REQUIRED"
  fi

  assignee_logins=$(echo "$pr" | jq -c '[.assignees[].login]')

  echo "  #${number} ${title}" >&2

  # Fetch comments and reviews
  comments_json=$(gh api "repos/{owner}/{repo}/issues/${number}/comments" 2>/dev/null || echo "[]")
  reviews_json=$(gh api "repos/{owner}/{repo}/pulls/${number}/reviews" 2>/dev/null || echo "[]")

  # Find last activity per user
  last_activity_for() {
    local user="$1"
    local lc lr
    lc=$(echo "$comments_json" | jq -r --arg u "$user" \
      '[.[] | select(.user.login == $u) | .created_at] | sort | last // empty')
    lr=$(echo "$reviews_json" | jq -r --arg u "$user" \
      '[.[] | select(.user.login == $u) | .submitted_at] | sort | last // empty')

    local best=""
    if [[ -n "$lc" && -n "$lr" ]]; then
      local ce re
      ce=$(parse_date "$lc"); re=$(parse_date "$lr")
      if (( ce > re )); then best="$lc"; else best="$lr"; fi
    elif [[ -n "$lc" ]]; then best="$lc"
    elif [[ -n "$lr" ]]; then best="$lr"
    fi
    echo "$best"
  }

  author_last=$(last_activity_for "$author")
  author_fallback="false"
  if [[ -z "$author_last" ]]; then
    author_last="$created_at"
    author_fallback="true"
  fi

  # Build assignees array with activity
  assignees_enriched="[]"
  for login in $(echo "$assignee_logins" | jq -r '.[]'); do
    a_last=$(last_activity_for "$login")
    if [[ -z "$a_last" ]]; then
      assignees_enriched=$(echo "$assignees_enriched" | jq -c --arg l "$login" '. + [{"login": $l, "lastActivity": null}]')
    else
      assignees_enriched=$(echo "$assignees_enriched" | jq -c --arg l "$login" --arg t "$a_last" '. + [{"login": $l, "lastActivity": $t}]')
    fi
  done

  # Output one JSON object per line
  jq -n -c \
    --argjson num "$number" \
    --arg title "$title" \
    --arg author "$author" \
    --arg url "$url" \
    --arg created "$created_at" \
    --arg status "$review_decision" \
    --arg authorLast "$author_last" \
    --argjson authorFallback "$author_fallback" \
    --argjson assignees "$assignees_enriched" \
    '{number: $num, title: $title, author: $author, url: $url, createdAt: $created, status: $status, authorLastActivity: $authorLast, authorIsFallback: $authorFallback, assignees: $assignees}'
done | jq -s '.' > /tmp/pr-dashboard-data.json

DATA=$(cat /tmp/pr-dashboard-data.json)

cat > "$OUTPUT" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PR Dashboard</title>
<style>
  :root {
    --bg: #0d1117;
    --card: #161b22;
    --border: #30363d;
    --text: #e6edf3;
    --dim: #8b949e;
    --green: #3fb950;
    --yellow: #d29922;
    --red: #f85149;
    --blue: #58a6ff;
    --purple: #bc8cff;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 24px;
    max-width: 960px;
    margin: 0 auto;
  }
  header {
    margin-bottom: 24px;
    padding-bottom: 16px;
    border-bottom: 1px solid var(--border);
  }
  header h1 { font-size: 1.5rem; font-weight: 600; }
  header .meta { color: var(--dim); font-size: 0.85rem; margin-top: 4px; }
  .legend {
    display: flex;
    gap: 16px;
    margin-top: 8px;
    font-size: 0.8rem;
    color: var(--dim);
  }
  .legend .dot {
    display: inline-block;
    width: 8px; height: 8px;
    border-radius: 50%;
    margin-right: 4px;
    vertical-align: middle;
  }
  .pr-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 16px;
    margin-bottom: 12px;
  }
  .pr-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 12px;
  }
  .pr-title-group { flex: 1; min-width: 0; }
  .pr-number {
    font-weight: 600;
    color: var(--dim);
    margin-right: 6px;
  }
  .pr-title {
    font-weight: 600;
    font-size: 1.05rem;
  }
  .pr-title a {
    color: var(--text);
    text-decoration: none;
  }
  .pr-title a:hover { color: var(--blue); text-decoration: underline; }
  .status-badge {
    font-size: 0.75rem;
    font-weight: 600;
    padding: 3px 10px;
    border-radius: 12px;
    white-space: nowrap;
    flex-shrink: 0;
  }
  .status-approved { background: rgba(63,185,80,0.15); color: var(--green); }
  .status-changes_requested { background: rgba(248,81,73,0.15); color: var(--red); }
  .status-review_required { background: rgba(210,153,34,0.15); color: var(--yellow); }
  .pr-people {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    font-size: 0.875rem;
  }
  .person-section label {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--dim);
    display: block;
    margin-bottom: 4px;
  }
  .person-section.author label { color: var(--blue); }
  .person-section.assignees label { color: var(--purple); }
  .person {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 2px 0;
  }
  .person-name {
    font-weight: 500;
  }
  .activity {
    font-size: 0.8rem;
    color: var(--dim);
  }
  .activity .time { font-weight: 500; }
  .activity .fallback { font-style: italic; opacity: 0.7; }
  .time-green { color: var(--green); }
  .time-yellow { color: var(--yellow); }
  .time-red { color: var(--red); }
  .no-activity { color: var(--dim); font-style: italic; }
  @media (max-width: 600px) {
    .pr-people { grid-template-columns: 1fr; }
    .pr-header { flex-direction: column; }
  }
</style>
</head>
<body>

<header>
  <h1>PR Dashboard</h1>
  <div class="meta">
    Label: <strong id="label-name"></strong>
    &middot; <span id="pr-count"></span> open PR(s)
    &middot; Generated: <span id="generated-at"></span>
  </div>
  <div class="legend">
    <span><span class="dot" style="background:var(--green)"></span> &lt; 1 day</span>
    <span><span class="dot" style="background:var(--yellow)"></span> 1–3 days</span>
    <span><span class="dot" style="background:var(--red)"></span> 3+ days</span>
  </div>
</header>

<main id="pr-list"></main>

<script>
HTMLEOF

# Inject the data
echo "const LABEL = $(echo -n "$LABEL" | jq -Rs '.');" >> "$OUTPUT"
echo "const GENERATED_AT = \"$generated_at\";" >> "$OUTPUT"
echo "const DATA = $DATA;" >> "$OUTPUT"

cat >> "$OUTPUT" <<'HTMLEOF'

function timeAgo(isoDate) {
  if (!isoDate) return null;
  const now = new Date();
  const then = new Date(isoDate);
  const diffMs = now - then;
  const diffMin = Math.floor(diffMs / 60000);
  const diffHr = Math.floor(diffMs / 3600000);
  const diffDay = Math.floor(diffMs / 86400000);
  if (diffMin < 60) return `${diffMin}m ago`;
  if (diffHr < 24) return `${diffHr}h ago`;
  return `${diffDay}d ago`;
}

function urgencyClass(isoDate) {
  if (!isoDate) return '';
  const diffMs = new Date() - new Date(isoDate);
  if (diffMs < 86400000) return 'time-green';
  if (diffMs < 259200000) return 'time-yellow';
  return 'time-red';
}

function statusLabel(s) {
  return s.replace(/_/g, ' ');
}

function statusClass(s) {
  return 'status-' + s.toLowerCase();
}

function renderActivity(isoDate, fallback) {
  if (!isoDate) return '<span class="no-activity">none</span>';
  const cls = urgencyClass(isoDate);
  const ago = timeAgo(isoDate);
  const suffix = fallback ? ' <span class="fallback">(created)</span>' : '';
  return `<span class="time ${cls}">${ago}</span>${suffix}`;
}

document.getElementById('label-name').textContent = LABEL;
document.getElementById('pr-count').textContent = DATA.length;
document.getElementById('generated-at').textContent = new Date(GENERATED_AT).toLocaleString();

const list = document.getElementById('pr-list');

DATA.forEach(pr => {
  const card = document.createElement('div');
  card.className = 'pr-card';

  const assigneesHtml = pr.assignees.length === 0
    ? '<span class="no-activity">none</span>'
    : pr.assignees.map(a =>
        `<div class="person">
          <span class="person-name">${a.login}</span>
          <span class="activity">${renderActivity(a.lastActivity, false)}</span>
        </div>`
      ).join('');

  card.innerHTML = `
    <div class="pr-header">
      <div class="pr-title-group">
        <span class="pr-number">#${pr.number}</span>
        <span class="pr-title"><a href="${pr.url}" target="_blank">${pr.title}</a></span>
      </div>
      <span class="status-badge ${statusClass(pr.status)}">${statusLabel(pr.status)}</span>
    </div>
    <div class="pr-people">
      <div class="person-section author">
        <label>Author</label>
        <div class="person">
          <span class="person-name">${pr.author}</span>
          <span class="activity">${renderActivity(pr.authorLastActivity, pr.authorIsFallback)}</span>
        </div>
      </div>
      <div class="person-section assignees">
        <label>Assigned</label>
        ${assigneesHtml}
      </div>
    </div>
  `;
  list.appendChild(card);
});
</script>
</body>
</html>
HTMLEOF

echo ""
echo "Dashboard written to: ${OUTPUT}"
echo "Open with: open ${OUTPUT}"
