# tool-mordecai-plan-approval

Plan-approval workflow for the Mordecai coding agent. Adds a two-phase **plan → approve → implement** flow so Josh can review Mordecai's approach before any code is written.

## Problem

Mordecai sometimes charges ahead with an implementation that doesn't match expectations. Rework is expensive — it's cheaper to review a plan than to review (and potentially reject) a full PR.

## Solution

Before Mordecai writes code, he generates a structured plan. Zev posts it to #zev-commands with reaction buttons. Josh reacts ✅ to approve or ✏️ to request corrections. Only after approval does Mordecai implement.

## Files

| File | What it does |
|------|-------------|
| `mordecai-plan.sh` | Spawns Mordecai in plan-only mode, parses the JSON plan, posts to Discord, sets up reaction-based approval |
| `check-plan-reaction.sh` | Checks Discord reactions on the plan message — returns `approved`, `corrections`, or `waiting` |
| `watch-mordecai.sh.patch` | Diff to apply to `~/.openclaw/workspace/scripts/watch-mordecai.sh` — adds `planning`, `awaiting_approval`, `correcting`, `implementing` states |
| `queue.sh.patch` | Diff to apply to `~/.openclaw/workspace/scripts/queue.sh` — adds `skip_plan` field support |
| `TOOLS-plan-approval.md` | Documentation section to add to `TOOLS.md` |

## New State Machine

```
Queue item picked up
        │
        ▼
  skip_plan: true? ──yes──▶ [active] (existing flow)
        │ no
        ▼
   [planning]
   Mordecai generates plan
        │
        ▼
  [awaiting_approval]
  Plan posted to Discord
  ✅ / ✏️ reactions
        │
   ┌────┴────┐
   ▼         ▼
 ✅         ✏️
   │         │
   ▼         ▼
[implementing]  [correcting]
   │             │
   ▼         (re-plan after
 existing     Josh's input)
 watcher
 flow
```

## Installation

These files go into `~/.openclaw/workspace/scripts/` after PR review.

1. Copy `mordecai-plan.sh` and `check-plan-reaction.sh` to `scripts/`
2. `chmod +x scripts/mordecai-plan.sh scripts/check-plan-reaction.sh`
3. Apply `watch-mordecai.sh.patch` to `scripts/watch-mordecai.sh`
4. Apply `queue.sh.patch` to `scripts/queue.sh`
5. Add contents of `TOOLS-plan-approval.md` to `TOOLS.md`

## skip_plan for Trivial Fixes

Set `skip_plan: true` on queue items that don't need a planning phase:

```bash
queue.sh set <issue> skip_plan true
```

**Trivial fix definition** (all must be true):
- Single file change (two files max, clearly identified)
- No DB migrations
- No new API endpoints
- No new UI components
- Fix is a value change, missing case, or typo — not new behavior

## Dependencies

- `openclaw` CLI (message send, react, reactions)
- `claude` CLI (dangerously-skip-permissions mode)
- `gh` CLI (issue title lookup)
- `python3` (JSON parsing)
- Existing workspace infrastructure: `agent-registry.sh`, `config/channels.env`

## No Secrets

All secrets (Discord tokens, API keys) are handled by the `openclaw` CLI at runtime. Nothing sensitive in this repo.

---

Built by Signet for the zev agents team.
