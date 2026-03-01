#!/bin/bash
# check-plan-reaction.sh — Check if Josh approved or requested corrections on Mordecai's plan
# Usage: check-plan-reaction.sh
#
# Reads plan_message_id from state.json, checks Discord reactions.
# Output (stdout):
#   "approved"    — Josh reacted ✅, status set to implementing
#   "corrections" — Josh reacted ✏️, status set to correcting
#   "waiting"     — no reaction from Josh yet

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/channels.env"

STATE_FILE="$HOME/.config/mordecai-watcher/state.json"
OPENCLAW="$HOME/.nvm/versions/node/v25.5.0/bin/openclaw"
ZEV_CHANNEL_ID="1477447993849544798"

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

# --- Load state ---

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file found at $STATE_FILE" >&2
  exit 1
fi

PLAN_MESSAGE_ID=$(python3 -c "
import json
d = json.load(open('$STATE_FILE'))
print(d.get('plan_message_id', ''))
" 2>/dev/null)

if [ -z "$PLAN_MESSAGE_ID" ]; then
  echo "No plan_message_id in state.json" >&2
  exit 1
fi

# --- Check reactions ---

REACTIONS=$($OPENCLAW message reactions --channel discord --message-id "$PLAN_MESSAGE_ID" --channel-id "$ZEV_CHANNEL_ID" 2>&1)

# Parse reactions to check for Josh's response
RESULT=$(python3 -c "
import json, sys

josh_id = '$JOSH_USER_ID'
text = sys.stdin.read().strip()

try:
    data = json.loads(text)
except json.JSONDecodeError:
    # If not JSON, try line-by-line parsing
    print('waiting')
    sys.exit(0)

# Handle both array-of-reactions and object formats
reactions = data if isinstance(data, list) else data.get('reactions', data.get('data', []))

josh_approved = False
josh_corrections = False

for reaction in reactions:
    emoji = reaction.get('emoji', {})
    emoji_name = emoji.get('name', '') if isinstance(emoji, dict) else str(emoji)
    users = reaction.get('users', [])

    # Check if Josh is in the users list
    josh_reacted = False
    for user in users:
        uid = user.get('id', str(user)) if isinstance(user, dict) else str(user)
        if uid == josh_id:
            josh_reacted = True
            break

    if josh_reacted:
        if emoji_name in ('✅', 'white_check_mark'):
            josh_approved = True
        elif emoji_name in ('✏️', '✏', 'pencil2'):
            josh_corrections = True

# ✅ takes priority over ✏️
if josh_approved:
    print('approved')
elif josh_corrections:
    print('corrections')
else:
    print('waiting')
" <<< "$REACTIONS" 2>/dev/null)

# --- Act on result ---

case "$RESULT" in
  approved)
    echo "approved"
    update_state status implementing
    ;;
  corrections)
    echo "corrections"
    update_state status correcting
    # Notify in #zev-commands that corrections are needed
    $OPENCLAW message send --channel discord --target "$ZEV_COMMANDS_CHANNEL" \
      --message "Got it — what needs changing? I'll update the plan before Mordecai starts." \
      2>/dev/null || true
    ;;
  *)
    echo "waiting"
    ;;
esac
