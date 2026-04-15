# PR Dashboard

Generates a static HTML page showing open pull requests for a given GitHub label, with author and assignee activity timestamps.

## Requirements

- [`gh`](https://cli.github.com/) — GitHub CLI, authenticated (`gh auth login`)
- [`jq`](https://stedolan.github.io/jq/)

## Usage

```bash
./pr-dashboard-html.sh <label> [output.html]
```

| Argument | Required | Description |
|---|---|---|
| `<label>` | Yes | GitHub label to filter PRs by |
| `[output.html]` | No | Output file path (default: `pr-dashboard.html`) |

## Examples

```bash
# Basic usage — output goes to pr-dashboard.html
./pr-dashboard-html.sh "Team Ruru 🦉"

# Specify a custom output file
./pr-dashboard-html.sh "bug" bug-dashboard.html

# Open immediately after generating
./pr-dashboard-html.sh "my-label" && open pr-dashboard.html
```

## What it shows

Each PR card displays:
- PR number, title (linked to GitHub), and review status badge
- **Author** — last comment or review activity (falls back to PR creation date if none)
- **Assignees** — last comment or review activity for each assignee

Activity timestamps are colour-coded:
- Green — less than 1 day ago
- Yellow — 1–3 days ago
- Red — 3+ days ago

## Alias

To run from anywhere, add a shell alias:

```bash
alias pr-dash='~/path/to/pr-dashboard-html.sh'
```

Then:

```bash
pr-dash "my-label" && open pr-dashboard.html
```
