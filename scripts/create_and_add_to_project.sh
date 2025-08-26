#!/usr/bin/env bash
set -euo pipefail

# Create GitHub issues from a CSV and add them to an existing Projects v2 project.
# Requirements:
# - gh CLI installed and authenticated (gh auth login)
# - jq installed
# - python3 (optional, used for robust CSV parsing)
# Usage:
#   ./scripts/create_and_add_to_project.sh owner/repo kanban.csv assignees_map.csv --project-title "Project Title"
#   or
#   ./scripts/create_and_add_to_project.sh owner/repo kanban.csv assignees_map.csv --project-id "PROJECT_GRAPHQL_ID"
# Example:
#   ./scripts/create_and_add_to_project.sh phbatista132/-DEVEC data/kanban-sample-no-qa-po.csv data/assignees_map.csv --project-title "Kanban - v1"

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 owner/repo kanban.csv assignees_map.csv --project-title \"Project Title\"  OR --project-id \"PROJECT_GRAPHQL_ID\""
  exit 1
fi

REPO="$1"
KANBAN_CSV="$2"
ASSIGNEES_CSV="$3"
shift 3

PROJECT_ID=""
PROJECT_TITLE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-id)
      PROJECT_ID="$2"
      shift 2
      ;; 
    --project-title)
      PROJECT_TITLE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. Install from https://cli.github.com/"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. Install jq to continue."
  exit 1
fi
if [ ! -f "$KANBAN_CSV" ]; then
  echo "Kanban CSV not found: $KANBAN_CSV"
  exit 1
fi
if [ ! -f "$ASSIGNEES_CSV" ]; then
  echo "Assignees map CSV not found: $ASSIGNEES_CSV"
  exit 1
fi

OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

# helper to get project GraphQL id by title
get_project_id_by_title() {
  title="$1"
  # Query projectsV2 nodes for the repository and find by title
  query='query($owner:String!, $repo:String!) { repository(owner:$owner, name:$repo) { projectsV2(first:100) { nodes { id title number } } } }'
  resp=$(gh api graphql -f query="${query}" -f owner="$OWNER" -f repo="$REPO_NAME")
  echo "$resp" | jq -r --arg TITLE "$title" '.data.repository.projectsV2.nodes[] | select(.title==$TITLE) | .id' | head -n1
}

# if PROJECT_TITLE provided, resolve PROJECT_ID
if [ -z "$PROJECT_ID" ] && [ -n "$PROJECT_TITLE" ]; then
  echo "Resolving project id for title: $PROJECT_TITLE"
  PROJECT_ID=$(get_project_id_by_title "$PROJECT_TITLE")
  if [ -z "$PROJECT_ID" ]; then
    echo "Could not find a project with title '$PROJECT_TITLE' in $REPO. Please provide --project-id instead or create the project first."
    exit 1
  fi
  echo "Found project id: $PROJECT_ID"
fi

if [ -z "$PROJECT_ID" ]; then
  echo "Project id not provided or found. Provide --project-id or --project-title."
  exit 1
fi

# Load assignee mapping
declare -A ASSIGNEE_MAP
while IFS=',' read -r csv_label github_user; do
  if [[ "$csv_label" =~ ^# ]] || [[ -z "$csv_label" ]] || [[ "$csv_label" == "csv_label" ]]; then
    continue
  fi
  csv_label_trimmed=$(echo "$csv_label" | xargs)
  github_user_trimmed=$(echo "$github_user" | xargs)
  ASSIGNEE_MAP["$csv_label_trimmed"]="$github_user_trimmed"
done < "$ASSIGNEES_CSV"

# Function to map assignee
map_assignee() {
  val="$1"
  val_trimmed=$(echo "$val" | xargs)
  echo "${ASSIGNEE_MAP[$val_trimmed]:-}"
}

# Read CSV robustly using python if available, otherwise naive
create_issues_and_add() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import csv,sys,subprocess,shlex
from subprocess import check_output, CalledProcessError
kanban = sys.argv[1]
ass_map = sys.argv[2]
repo = sys.argv[3]
project_id = sys.argv[4]
# load assignee map
amap = {}
with open(ass_map, newline='', encoding='utf-8') as f:
    reader = csv.reader(f)
    for row in reader:
        if not row or row[0].strip().startswith('#') or row[0].strip()== 'csv_label':
            continue
        key = row[0].strip()
        val = row[1].strip() if len(row)>1 else ''
        amap[key]=val

with open(kanban, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for r in reader:
        title = r.get('Title') or r.get('Name') or 'Untitled'
        labels = r.get('Labels','')
        assignee_label = (r.get('Assignee') or '').strip()
        mapped = amap.get(assignee_label,'')
        # build body
        body_lines = []
        for k in ['Type','Status','Swimlane','Priority','Product Lead','Estimate','Dependencies','Created','Blocked Reason','Release Version']:
            if r.get(k):
                body_lines.append(f"{k}: {r.get(k)}")
        body_lines.append('\nDescription:\n'+(r.get('Description') or ''))
        body_lines.append('\nAcceptance Criteria:\n'+(r.get('Acceptance Criteria') or ''))
        body_lines.append('\nChecklist:\n'+(r.get('Checklist') or ''))
        body = '\n'.join(body_lines)
        cmd = [
            'gh','issue','create','--repo',repo,'--title',title,'--body',body
        ]
        if labels:
            for lab in [l.strip() for l in labels.split(',') if l.strip()]:
                cmd += ['--label',lab]
        if mapped:
            cmd += ['--assignee', mapped]
        try:
            print('Creating issue:', title)
            out = check_output(cmd, text=True)
            # gh issue create prints the URL; parse issue number
            url = out.strip().split('\n')[-1]
            # fetch issue by API to get node_id
            # extract number from url
            issue_number = url.rstrip('/').split('/')[-1]
            issue_info = check_output(['gh','api',f"repos/{repo}/issues/{issue_number}" , '--jq', '.node_id'], text=True).strip()
            content_id = issue_info
            # add to project
            mutation = 'mutation($projectId:ID!, $contentId:ID!){ addProjectV2ItemByContent(input:{projectId:$projectId, contentId:$contentId}){ item{ id } } }'
            # call graphql
            proc = check_output(['gh','api','graphql','-f',f'query={mutation}','-f',f'projectId={project_id}','-f',f'contentId={content_id}'], text=True)
            print('Added to project:', title)
        except CalledProcessError as e:
            print('Failed to create or add:', title)
            print(e.output)
PY
  else
    echo "python3 not found: this script uses python3 to parse CSV robustly."
    exit 1
  fi
}

create_issues_and_add "$KANBAN_CSV" "$ASSIGNEES_CSV" "$REPO" "$PROJECT_ID"

echo "Done. Issues created and added to project."