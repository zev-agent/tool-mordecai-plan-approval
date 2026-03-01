#!/bin/bash
# mordecai-plan.sh — Spawn Mordecai in plan-only mode, post plan to Discord for approval
# Usage: mordecai-plan.sh <issue> <repo> <task_file> <workdir>
#
# Flow:
#   1. Spawns Mordecai with a plan-only prompt (no code writing)
#   2. Parses JSON plan from Mordecai's log output
#   3. Formats and posts plan to #zev-commands
#   4. Adds ✅ and ✏️ reactions for Josh to approve/correct
#   5. Saves plan_message_id to state.json, sets status to awaiting_approval

set -e

ISSUE="$1"
REPO="$2"
TASK_FILE="$3"
WORKDIR="$4"

if [ -z "$ISSUE" ] || [ -z "$REPO" ] || [ -z "$TASK_FILE" ] || [ -z "$WORKDIR" ]; then
  echo "Usage: mordecai-plan.sh <issue> <repo> <task_file> <workdir>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/agent-registry.sh"
source "$SCRIPT_DIR/../config/channels.env"

STATE_FILE="$HOME/.config/mordecai-watcher/state.json"
OPENCLAW="$HOME/.nvm/versions/node/v25.5.0/bin/openclaw"
PLAN_LOG="$HOME/mordecai/logs/mordecai-plan-$ISSUE.log"

mkdir -p "$(dirname "$PLAN_LOG")"

# --- Helpers ---

update_state() {
  python3 -c "
import json, sys
d = json.load(open('$STATE_FILE'))
args = sys.argv[1:]
for i in range(0, len(args), 2):
    k, v = args[i], args[i+1]
    d[k] = int(v) if v.isdigit() else v
json.dump(d, open('$STATE_FILE', 'w'), indent=2)
" "$@"
}

# --- Step 1: Build plan-only prompt ---

TASK_CONTENT="$(cat "$TASK_FILE")"

# Get issue title from GitHub
ISSUE_TITLE=$(gh issue view "$ISSUE" --repo "$REPO" --json title --jq '.title' 2>/dev/null || echo "Issue #$ISSUE")

PLAN_PROMPT="You are Mordecai, a coding agent. You are in PLAN-ONLY mode.

## Task
$TASK_CONTENT

## Instructions
1. Read the task above carefully
2. Explore the codebase in $WORKDIR to understand the current state
3. Produce a plan — do NOT write any code, do NOT create any files, do NOT make any commits

Output ONLY valid JSON in this exact format (no markdown fences, no commentary):
{
  \"approach\": \"2-3 sentence summary of what you will do\",
  \"files\": [
    {\"path\": \"relative/path/to/file\", \"change\": \"what changes and why\"}
  ],
  \"test_strategy\": \"how you will test this — unit tests, E2E, manual verification\",
  \"scope\": \"small|medium|large\",
  \"questions\": [\"any blocking questions before implementation — empty array if none\"]
}

Rules:
- Output ONLY the JSON object. Nothing else.
- Do not wrap in markdown code fences.
- Do not write any code or create any files.
- 'scope' must be exactly one of: small, medium, large
- 'files' must list every file you plan to touch
- If you have no questions, use an empty array: []"

# --- Step 2: Spawn Mordecai in plan mode ---

echo "Spawning Mordecai in plan-only mode for issue #$ISSUE..."
update_state status planning

cd "$WORKDIR"
claude --dangerously-skip-permissions "$PLAN_PROMPT" > "$PLAN_LOG" 2>&1
PLAN_EXIT=$?

if [ $PLAN_EXIT -ne 0 ]; then
  echo "Mordecai plan generation failed (exit $PLAN_EXIT). Check $PLAN_LOG"
  update_state status escalated
  $OPENCLAW message send --channel discord --target "$ZEV_COMMANDS_CHANNEL" \
    --message "⚠️ Mordecai plan generation failed for issue #$ISSUE. Exit code: $PLAN_EXIT. Log: \`$PLAN_LOG\`" \
    2>/dev/null || true
  exit 1
fi

# --- Step 3: Parse JSON from Mordecai's output ---

PLAN_JSON=$(python3 -c "
import json, sys, re

with open('$PLAN_LOG') as f:
    content = f.read()

# Try to find JSON object in the output
# Look for the outermost { ... } block
match = re.search(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', content, re.DOTALL)
if not match:
    print('ERROR: No JSON found in plan output', file=sys.stderr)
    sys.exit(1)

raw = match.group(0)

try:
    plan = json.loads(raw)
except json.JSONDecodeError as e:
    print(f'ERROR: Invalid JSON in plan output: {e}', file=sys.stderr)
    sys.exit(1)

# Validate required fields
for field in ('approach', 'files', 'test_strategy', 'scope'):
    if field not in plan:
        print(f'ERROR: Missing required field: {field}', file=sys.stderr)
        sys.exit(1)

print(json.dumps(plan))
" 2>&1)

if echo "$PLAN_JSON" | grep -q '^ERROR:'; then
  echo "Failed to parse plan: $PLAN_JSON"
  update_state status escalated
  $OPENCLAW message send --channel discord --target "$ZEV_COMMANDS_CHANNEL" \
    --message "⚠️ Mordecai produced an unparseable plan for issue #$ISSUE. Check log: \`$PLAN_LOG\`" \
    2>/dev/null || true
  exit 1
fi

# Save raw plan JSON to state dir
echo "$PLAN_JSON" > "$HOME/.config/mordecai-watcher/plan-$ISSUE.json"

# --- Step 4: Format Discord message ---

DISCORD_MSG=$(python3 -c "
import json, sys

plan = json.loads(sys.argv[1])
issue = sys.argv[2]
title = sys.argv[3]

# Capitalize scope
scope = plan.get('scope', 'medium').capitalize()

lines = []
lines.append(f'🔩 **Mordecai — Plan for issue #{issue}: {title}**')
lines.append('')
lines.append('**Approach:**')
lines.append(plan['approach'])
lines.append('')
lines.append('**Files to change:**')
for f in plan.get('files', []):
    lines.append(f'• \`{f[\"path\"]}\` — {f[\"change\"]}')
lines.append('')
lines.append('**Test strategy:**')
lines.append(plan['test_strategy'])
lines.append('')
lines.append(f'**Scope:** {scope}')

questions = plan.get('questions', [])
if questions:
    lines.append('')
    lines.append('**Open questions:**')
    for q in questions:
        lines.append(f'• {q}')
    lines.append('')

lines.append('')
lines.append('React to proceed:')
lines.append('✅ Approve — start implementation')
lines.append('✏️ Corrections needed')

print('\n'.join(lines))
" "$PLAN_JSON" "$ISSUE" "$ISSUE_TITLE")

# --- Step 5: Post to Discord and add reactions ---

echo "Posting plan to #zev-commands..."
POST_RESULT=$($OPENCLAW message send --channel discord --target "$ZEV_COMMANDS_CHANNEL" --message "$DISCORD_MSG" 2>&1)

# Extract message ID from the post result
MESSAGE_ID=$(echo "$POST_RESULT" | python3 -c "
import sys, re, json
text = sys.stdin.read()
# Try JSON parse first
try:
    d = json.loads(text)
    mid = d.get('id') or d.get('message_id') or d.get('messageId')
    if mid:
        print(mid)
        sys.exit(0)
except (json.JSONDecodeError, KeyError):
    pass
# Fallback: look for a numeric ID in the output
match = re.search(r'(\d{17,20})', text)
if match:
    print(match.group(1))
else:
    print('', end='')
" 2>/dev/null)

if [ -z "$MESSAGE_ID" ]; then
  echo "Warning: Could not extract message ID from post result. Plan posted but reactions/tracking may fail."
  echo "Post result: $POST_RESULT"
  # Still update state — we can try to find the message later
  update_state status awaiting_approval
  exit 0
fi

echo "Plan posted (message ID: $MESSAGE_ID). Adding reactions..."

# Add approval reactions
$OPENCLAW message react --channel discord --message-id "$MESSAGE_ID" --channel-id 1477447993849544798 --emoji "✅" 2>/dev/null || true
$OPENCLAW message react --channel discord --message-id "$MESSAGE_ID" --channel-id 1477447993849544798 --emoji "✏️" 2>/dev/null || true

# --- Step 6: Update state ---

update_state status awaiting_approval plan_message_id "$MESSAGE_ID"

echo "Plan posted and awaiting approval. Message ID: $MESSAGE_ID"
echo "State updated to awaiting_approval."
