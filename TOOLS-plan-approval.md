## Plan-Approval Workflow (Mordecai)

Two-phase flow for Mordecai tasks: **plan → approve → implement**. Ensures Josh reviews the approach before any code is written.

### How It Works

1. **Plan phase:** Mordecai spawns in plan-only mode — reads the task, explores the codebase, outputs a structured JSON plan (approach, files, test strategy, scope, questions). No code is written.
2. **Post to Discord:** Zev formats the plan and posts it to #zev-commands with ✅ (approve) and ✏️ (corrections needed) reactions.
3. **Approval gate:** The watcher polls for Josh's reaction:
   - **✅ Approve** → state moves to `implementing`, Mordecai starts coding with the approved plan context
   - **✏️ Corrections** → state moves to `correcting`, Zev asks Josh what needs changing, then re-runs the planning phase
4. **Implementation:** Mordecai codes against the approved plan. Normal watcher monitoring (restart, escalate, PR detection) applies from here.

### State Machine (new states)

| State | Meaning |
|-------|---------|
| `planning` | Mordecai is generating the plan (agent running) |
| `awaiting_approval` | Plan posted to Discord, waiting for Josh's reaction |
| `correcting` | Josh reacted ✏️, waiting for corrections input |
| `implementing` | Approved, Mordecai is coding |

These join the existing states: `active`, `pr_open`, `done`, `escalated`.

### Skipping the Plan Phase (`skip_plan`)

For trivial fixes, set `skip_plan: true` on the queue item to go straight to implementation:

```bash
queue.sh set <issue> skip_plan true
```

**Trivial fix definition** (all must be true):
- Single file change (two files max, clearly identified)
- No DB migrations
- No new API endpoints
- No new UI components
- Fix is a value change, missing case, or typo — not new behavior

When in doubt, don't skip. The planning phase is cheap (one Claude invocation) and catches bad assumptions early.

### Scripts

| Script | Purpose |
|--------|---------|
| `mordecai-plan.sh <issue> <repo> <task_file> <workdir>` | Spawns Mordecai in plan-only mode, posts formatted plan to Discord |
| `check-plan-reaction.sh` | Polls Discord for Josh's reaction on the plan message |

### Reaction-Based Approval

The plan message in #zev-commands looks like:

```
🔩 Mordecai — Plan for issue #42: Add user authentication

Approach:
Implement JWT-based auth with...

Files to change:
• `src/auth/handler.go` — add JWT validation middleware
• `src/routes/login.go` — new login endpoint

Test strategy:
Unit tests for JWT validation, E2E for login flow

Scope: Medium

React to proceed:
✅ Approve — start implementation
✏️ Corrections needed
```

Josh reacts directly on the message. The watcher checks every 30 minutes via cron.
