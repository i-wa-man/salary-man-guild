# AI Swarm System - Technical Specification

> **Version**: 3.0
> **Self-contained**: This document is designed to be portable to other environments.
> All implementation details are included without external dependencies.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Deployment](#3-deployment)
4. [Configuration Reference](#4-configuration-reference)
5. [Router Behavior](#5-router-behavior)
6. [Worker Behavior](#6-worker-behavior)
7. [Communication Protocol](#7-communication-protocol)
8. [Project Management & Phase DAG](#8-project-management--phase-dag)
9. [Autonomy Model](#9-autonomy-model)
10. [Skill Proposal System](#10-skill-proposal-system)
11. [Quality Gates](#11-quality-gates)
12. [Context Management](#12-context-management)
13. [Knowledge & Memory Bloat Mitigation](#13-knowledge--memory-bloat-mitigation)
14. [Google Workspace Integration](#14-google-workspace-integration)
15. [Dashboard & Auto-Sync](#15-dashboard--auto-sync)
16. [Cost Control](#16-cost-control)
17. [Error Handling & Timeouts](#17-error-handling--timeouts)
18. [Team Definitions](#18-team-definitions)
19. [File Structure Reference](#19-file-structure-reference)

---

## 1. Overview

AI Swarm is a multi-agent parallel development platform built on **Claude Code CLI + psmux** (Windows-native tmux alternative, Rust-based, compatible with tmux command syntax).

The system organizes AI agents into **domain-specialized teams**. Each team operates independently within its own psmux session and handles a specific business domain (development, design, operations, content, SNS, strategy, etc.).

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Domain teams (not task-type teams) | Each team runs the full research→plan→execute→review→improve cycle internally |
| Deploy only needed teams | No need to run all teams simultaneously; saves cost |
| Teams are independent | Inter-team coordination via file-based handoffs only |
| Skills are global | `~/.claude/skills/` shared by all agents across all teams |
| Knowledge accumulates | Project `knowledge` section grows over time, improving quality |
| Autonomy grows | L1→L2→L3 promotion based on track record |
| Event-driven only | Polling is **forbidden** to control API costs |

---

## 2. Architecture

### 2.1 Team Structure

Each team consists of **1 Router + 5 Workers = 6 agents**, each running in a separate psmux pane within a dedicated psmux session.

```
User (Human)
 │
 ├── design   [Router + Worker×5]   UI/UX, graphics
 ├── dev      [Router + Worker×5]   Software development
 ├── ops      [Router + Worker×5]   Operations, monitoring
 ├── article  [Router + Worker×5]   Articles, blog posts
 ├── sns      [Router + Worker×5]   Social media management
 ├── strategy [Router + Worker×5]   Business strategy
 └── (extensible: add teams as needed)
```

### 2.2 psmux Session Layout (per team)

```
psmux session: {team_name}
├── Window: router    [1 pane]    Router (Opus)
└── Window: workers   [5 panes]   Worker_0..Worker_4 (Sonnet or Opus)
```

Each pane has two custom psmux variables set at deploy time:
- `@agent_id`: `router`, `worker_0`, `worker_1`, ..., `worker_4`
- `@team_name`: `dev`, `design`, `article`, etc.

Agents retrieve their identity at startup:
```powershell
psmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
psmux display-message -t "$TMUX_PANE" -p '#{@team_name}'
```

### 2.3 Formation Modes

| Mode | Router Model | Worker Model | Router Thinking | Command Flag |
|------|-------------|-------------|-----------------|-------------|
| **Default** | Opus | Sonnet | Disabled (`MAX_THINKING_TOKENS=0`) | _(none)_ |
| **Battle** | Opus | Opus | Enabled | `-Battle` |

- **Default mode**: Cost-efficient. Router dispatches fast without deep reasoning; Workers (Sonnet) handle execution with thinking enabled.
- **Battle mode**: Maximum quality. All agents run Opus with thinking enabled. Use for critical/complex tasks.

### 2.4 Agent Roles

**Router (1 per team)**:
- Receives requests from the user
- Decomposes requests into tasks on the team board
- Assigns tasks to Workers via send-keys
- Collects results, runs quality gates
- Manages phase transitions and autonomy decisions
- Updates dashboard and Google Sheets
- Evaluates skill proposals from Workers
- Handles inter-team handoffs (L2+)
- **Never executes tasks itself**

**Worker (5 per team)**:
- Claims pending tasks from the board
- Reads project context and domain knowledge
- Executes tasks using team domain expertise
- Performs self-review before reporting
- Reports results with mandatory `skill_candidate` field
- Notifies Router on completion
- **Never contacts the user directly**

---

## 3. Deployment

### 3.1 Prerequisites

- **psmux**: Windows-native tmux (Rust-based). Commands are identical to tmux.
- **Claude Code CLI**: `claude` command available in PATH.
- **gog** (optional): Google Sheets/Drive CLI tool for dashboard sync.

### 3.2 Deploy Script (`deploy.ps1`)

PowerShell script that creates psmux sessions, launches Claude Code, and loads instructions.

```powershell
# Single team
./deploy.ps1 dev

# Multiple teams
./deploy.ps1 dev article sns

# All defined teams
./deploy.ps1 -All

# Battle mode (all Opus)
./deploy.ps1 dev -Battle

# Fresh board (backup existing, create empty)
./deploy.ps1 dev -Clean

# Create sessions without launching Claude (for debugging)
./deploy.ps1 dev -SetupOnly

# List available teams
./deploy.ps1 -List
```

### 3.3 Deployment Sequence (per team)

1. **Kill existing session** if present
2. **Board management**: `-Clean` backs up and resets; otherwise ensures board file exists
3. **Status file**: Create `status/{team}.yaml` if missing
4. **Create psmux session**:
   - Window `router`: 1 pane, set `@agent_id=router`, `@team_name={team}`
   - Window `workers`: 5 panes (split-window horizontal/vertical alternating, tiled layout), set `@agent_id=worker_0..4`, `@team_name={team}`
   - Pane border labels show `{team_name}/{agent_id}`
5. **Launch Claude Code** (unless `-SetupOnly`):
   - Router: `[MAX_THINKING_TOKENS=0] claude --model opus --dangerously-skip-permissions`
   - Workers: `claude --model {sonnet|opus} --dangerously-skip-permissions` (500ms stagger)
6. **Wait for ready**: Poll Router pane (max 30s) for "bypass permissions" prompt
7. **Send initial instructions**:
   - Router: `"Read router.md, teams/{team}.yaml, config.yaml. You are the Router of the {team} team."`
   - Workers (2s stagger): `"Read worker.md and teams/{team}.yaml. You are worker_{N} in the {team} team."`

### 3.4 Runtime Directories (auto-created)

```
boards/          # Task boards per team
results/         # Task result files
projects/        # Project definitions
handoffs/        # Inter-team handoff files
status/          # Team status YAML files
skill-proposals/ # Skill proposal files
```

### 3.5 Dashboard Watcher (Background)

`deploy.ps1` starts a background PowerShell job that:
- Polls `status/*.yaml` every **10 seconds** for file changes (by LastWriteTime)
- Regenerates `status.md` (markdown dashboard)
- Syncs to Google Sheets via `gog` (if `spreadsheet_id` is configured)
- Non-fatal: Sheets sync failure does not affect local dashboard

### 3.6 Connecting to Sessions

```powershell
psmux attach -t dev          # Connect to dev team
psmux attach -t article      # Connect to article team
# Switch windows inside psmux:
# Ctrl+B, 0 → router window
# Ctrl+B, 1 → workers window
```

---

## 4. Configuration Reference

All configuration lives in `config.yaml`. Below is every section explained.

### 4.1 Models

```yaml
models:
  default:
    router: opus
    router_thinking: false    # Fast dispatch, no deep reasoning
    worker: sonnet
    worker_thinking: true     # Workers think through execution
  battle:
    router: opus
    router_thinking: true     # Full reasoning for all
    worker: opus
    worker_thinking: true

workers_per_team: 5           # Fixed: 5 workers per team
```

### 4.2 Google Workspace

```yaml
google:
  tool: gog                   # CLI tool name (gog or gws)
  dashboard:
    enabled: true
    spreadsheet_id: ""        # Google Sheets ID (from URL between /d/ and /edit)
    sheets:
      projects: "Projects"    # Tab names in the spreadsheet
      active: "Active"
      completed: "Completed"
      proposals: "Skills"
  drive:
    enabled: true             # Projects can reference Google Drive paths
```

### 4.3 Autonomy

```yaml
autonomy:
  default_level: L1           # All projects start at L1
  levels:
    L1: "All gates require user confirmation"
    L2: "Only strategic decisions need confirmation"
    L3: "Report only on anomalies"
  decision_types:             # Per-decision-type initial level
    quality_gate: L1
    phase_transition: L1
    strategy_choice: L1
    task_decompose: L2        # Router decides from the start
    worker_assign: L2         # Router decides from the start
    external_publish: L1      # Cannot be promoted
  promotion:
    L1_to_L2:
      condition: "3 consecutive approvals of same decision type"
    L2_to_L3:
      condition: "10+ tasks completed without issues at L2"
    demotion:
      condition: "User rejects a deliverable"
      action: "Immediate -1 level. Reason recorded in Memory MCP."
  always_ask:                 # Override: always ask regardless of level
    - "Budget decisions"
    - "External publishing/sending"
    - "Policy changes"
```

### 4.4 Memory MCP

```yaml
memory:
  enabled: true
  storage: memory/swarm_memory.jsonl
  save_triggers:
    - "User states a preference (tone, policy)"
    - "Cross-project reusable insight"
    - "Autonomy level promotion/demotion history"
    - "Skill proposal approval/rejection reasons"
  do_not_save:
    - "Task details (in YAML)"
    - "File contents (can be read)"
    - "In-progress task status (on board)"
```

### 4.5 Skill Proposals

```yaml
skill_proposals:
  dir: "skill-proposals"
  criteria:
    - "Pattern usable by other teams"
    - "Same procedure executed 2+ times"
    - "Procedure requiring specialized knowledge"
    - "Automation would stabilize quality"
```

### 4.6 Quality

```yaml
quality:
  review_skill: "/review"          # Skill used for quality review
  require_review_for: [high]       # Only high-priority tasks get /review
```

### 4.7 Context Management

```yaml
context:
  worker_threshold_percent: 50     # Worker monitors status line
  action_on_threshold: "save_progress → report → /clear → resume"
```

### 4.8 Communication

```yaml
communication:
  send_keys:
    method: two_calls              # Message and Enter in separate calls
    interval_between_workers: 2    # 2s between consecutive worker notifications
  handoffs:
    dir: "handoffs"          # Inter-team handoff files
```

### 4.9 Cost Control

```yaml
cost:
  polling: forbidden               # NEVER poll. Event-driven only.
  clear_after_task: true           # Workers /clear after task completion
  max_concurrent_opus: 4           # Limit Opus instances (non-battle mode)
```

### 4.10 Dashboard

```yaml
dashboard:
  auto_sync: true
  watch_interval_seconds: 10       # Background watcher interval
```

### 4.11 Timeouts

```yaml
timeouts:
  task_stale_minutes: 10           # Re-assign if task not completed
  worker_idle_minutes: 30          # Recommend /clear for idle workers
```

### 4.12 Paths

```yaml
paths:
  teams: "teams"
  boards: "boards"
  results: "results"
  projects: "projects"
  handoffs: "handoffs"
  status_dir: "status"
  status_md: "status.md"
  skill_proposals: "skill-proposals"
```

---

## 5. Router Behavior

### 5.1 Startup Sequence

```
1. Read router.md (instructions)
2. Read config.yaml (global config)
3. Get own team name: psmux display-message -t "$TMUX_PANE" -p '#{@team_name}'
4. Read teams/{team}.yaml (domain definition)
5. Read teams/{team}/CLAUDE.md (domain knowledge: principles, guidelines, quality criteria)
6. Read boards/{team}.yaml (existing tasks)
7. Read related projects/{id}.yaml (if applicable)
8. Report ready to user
```

### 5.2 Task Decomposition

**Step 1 — Decompose**: Break user request into independent tasks.
- Parallelizable work → separate tasks for simultaneous Worker execution
- Dependencies → use `depends_on` to enforce ordering
- Each task must have clear completion criteria

**Step 2 — Assign Phases**: Not all tasks need all 5 phases. Router decides based on task nature:

| Pattern | Phases |
|---------|--------|
| Simple fix | execute → review |
| New creation | research → plan → execute → review |
| Large-scale | research → plan → execute → review → improve |
| Urgent | execute only |

**Step 3 — Write to Board**: Create task entries in `boards/{team}.yaml`:

```yaml
tasks:
  - id: task_001
    status: pending           # pending / assigned / done / failed / blocked
    phase: research           # Current phase
    priority: high            # high / medium / low
    assigned_to: null         # Worker ID when claimed
    description: |
      What to do. Clear completion criteria:
        - Criterion 1
        - Criterion 2
    depends_on: []            # Task IDs this depends on
    project: null             # Project ID if applicable
    context:
      files: []               # Relevant file paths
      previous_results: []    # Result files from prior phases
      knowledge: |            # Extracted from project knowledge
        (Only what the Worker needs)
    created_at: ""            # Must use `date` command, never guess
    completed_at: null
```

**Step 4 — Wake Workers**: Use send-keys 2-call protocol (see §7).

**Step 5 — Stop and Wait**: Router halts. Workers wake Router via send-keys when done. **No polling.**

### 5.3 Result Collection

When woken by a Worker:

1. **Scan ALL results** in `results/` (not just the reporter's — catches missed notifications)
2. **Update board**: Set completed tasks to `status: done`
3. **Quality gate**: For `priority: high` tasks, run `/review` skill with `context: fork` (independent sub-agent)
4. **Phase transition**: If all `depends_on` tasks are done + gate passed → create next-phase tasks with `context.previous_results` pointing to completed results
5. **Skill proposals**: Check Worker results for `skill_candidate: found: true` → evaluate
6. **Dashboard**: Update `status/{team}.yaml` + Sheets sync

### 5.4 Phase Transition Example

```yaml
# Phase 1 completed: research
- id: task_001
  phase: research
  status: done

# Phase 2 created: execute (inherits research results)
- id: task_002
  phase: execute
  depends_on: [task_001]
  context:
    previous_results: ["results/task_001_result.yaml"]
    knowledge: |
      Target: Males 30s, IT industry
      Tone: Professional but approachable
```

### 5.5 Forbidden Actions

| ID | Action | Rule |
|----|--------|------|
| F001 | self_execute_task | Router must never execute tasks itself. Delegate to Workers. |
| F002 | polling | Polling forbidden. Event-driven only. |

---

## 6. Worker Behavior

### 6.1 Startup Sequence

```
1. Read worker.md (instructions)
2. Get own ID: psmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
   → e.g., worker_0, worker_1, ...
3. Get team name: psmux display-message -t "$TMUX_PANE" -p '#{@team_name}'
   → e.g., dev, design, article, ...
4. Read teams/{team}.yaml (domain definition)
5. Read teams/{team}/CLAUDE.md (domain knowledge: principles, guidelines, quality criteria)
6. Read boards/{team}.yaml (check for pending tasks)
7. Ready
```

### 6.2 Task Execution Workflow

**Step 1 — Read Board**: Find tasks matching:
- `status: pending`
- All `depends_on` tasks are `done`
- Prefer `priority: high`

**Step 2 — Claim Task**: Edit board to prevent race conditions:
```yaml
# Before                    # After
status: pending      →      status: assigned
assigned_to: null    →      assigned_to: worker_2
```

**Step 3 — Read Context**:

| Field | Action |
|-------|--------|
| `project` | Read `projects/{project}.yaml` |
| `context.files` | Read listed files |
| `context.previous_results` | Read prior phase result files |
| `context.knowledge` | Use domain knowledge in task |

**Step 4 — Execute**: Perform the task as a domain expert (defined by `teams/{team}.yaml` → `domain.what` and `teams/{team}/CLAUDE.md` → domain knowledge). May use any global skills in `~/.claude/skills/`.

**Step 5 — Self-Review**: Before writing result:
- All completion criteria met?
- Quality sufficient?
- No typos or obvious errors?

**Step 6 — Write Result** (`results/{task_id}_result.yaml`):

```yaml
task_id: task_001
worker_id: worker_2
team: dev
timestamp: "2026-03-29T10:30:00"    # date command. Never guess.
status: done                          # done / failed / blocked

result:
  summary: "1-2 sentence description of what was done"
  files_modified:
    - path/to/file1.ts
    - path/to/file2.ts
  deliverables:
    - path/to/output_file
  notes: "Anything the Router should know"

skill_candidate:                      # MANDATORY every time
  found: false
  name: null
  description: null
  reason: null
```

**Step 7 — Update Board**: Set `status: done`, fill `completed_at` (via `date` command).

**Step 8 — Notify Router**:
1. Check Router is idle: `psmux capture-pane -t {session}:router.0 -p | tail -5` (look for `❯` prompt)
2. If idle → send-keys 2-call protocol
3. If busy → wait 10s, retry (max 3 attempts)
4. After 3 failures: result file exists; Router will find it on next scan

**Step 9 — Next Task or Stop**: Check board for more `pending` tasks. If none, stop and wait.

### 6.3 Failure Reporting

```yaml
status: failed
result:
  summary: "Why it failed"
  error: "Specific error details"
  notes: "Retryable? Alternative approach needed?"
```

### 6.4 Blocked Reporting

```yaml
status: blocked
result:
  summary: "Why it's blocked"
  blocked_by: "What we're waiting for"
  notes: "Conditions for unblocking"
```

### 6.5 Skill Candidate Criteria

| Condition | Set `found: true` |
|-----------|-------------------|
| Same procedure executed 2+ times | Yes |
| Usable by other teams | Yes |
| Complex procedure requiring knowledge | Yes |
| Automation would stabilize quality | Yes |
| One-time task | No |

### 6.6 Forbidden Actions

| ID | Action | Rule |
|----|--------|------|
| F001 | direct_user_contact | Never talk to user directly. Report to Router. |
| F002 | polling | Polling forbidden. Event-driven only. |
| F003 | work_without_task | Never do work not on the board. |
| F004 | modify_other_results | Never touch another Worker's result files. |

---

## 7. Communication Protocol

### 7.1 send-keys 2-Call Protocol

**All inter-agent communication uses psmux send-keys. The message and Enter keystroke MUST be sent in two separate calls.** Sending them in a single call causes Enter to be misinterpreted.

```powershell
# Call 1: Send the message text
psmux send-keys -t {session}:{window}.{pane} 'Message content here'

# Call 2: Send Enter (separate invocation)
psmux send-keys -t {session}:{window}.{pane} Enter
```

### 7.2 Worker Notification Interval

When waking multiple Workers for parallel tasks, insert a **2-second delay** between each:

```powershell
psmux send-keys -t dev:workers.0 'New task on board. Check boards/dev.yaml.'
psmux send-keys -t dev:workers.0 Enter
sleep 2
psmux send-keys -t dev:workers.1 'New task on board. Check boards/dev.yaml.'
psmux send-keys -t dev:workers.1 Enter
```

### 7.3 Communication Flow

```
Within a team:
  User → Router          : Direct conversation (user types in Router pane)
  Router → Worker        : send-keys 2-call + board YAML
  Worker → Router        : send-keys 2-call + result YAML
  Router → Board         : Edit boards/{team}.yaml
  Worker → Result        : Write results/{task_id}_result.yaml
  Router → Status        : Edit status/{team}.yaml
  Router → Sheets        : gog CLI command (if enabled)

Between teams:
  Router A → handoff file → Router B  (send-keys to wake)
```

### 7.4 Idle Detection

Before sending a message, the sender checks if the receiver is idle:

```powershell
psmux capture-pane -t {session}:{window}.{pane} -p | tail -5
```

- **Idle**: Prompt symbol (`❯`) visible → safe to send
- **Busy**: "thinking", "Effecting…" visible → wait 10s, retry (max 3)

### 7.5 Event-Driven Design (No Polling)

**Polling is explicitly forbidden** (`cost.polling: forbidden` in config).

- Agents send results and stop
- Agents are woken by incoming send-keys messages
- If a notification fails to arrive, Router's periodic result scan (triggered by other events) catches orphaned results
- Dashboard watcher is the ONLY polling component (background job, 10s interval, minimal cost)

---

## 8. Project Management & Phase DAG

### 8.1 Project Definition (`projects/{id}.yaml`)

```yaml
project:
  id: "product_x"
  name: "Product X Launch"
  status: active              # active / paused / done
  autonomy: L1                # This project's autonomy level

  paths:
    drive: "G:/My Drive/Projects/product_x"   # Google Drive sync path
    local: "C:/work/product_x"                # Local workspace

  teams: [strategy, article, sns]             # Teams involved

  knowledge:
    target_audience: "Males 30s, IT industry"
    tone: "Professional but approachable"
    competitors: ["CompanyA", "CompanyB"]
    tech_stack: ["Next.js", "Prisma", "PostgreSQL"]

    decisions:                # Chronological decision log
      - date: "2026-03-29"
        what: "Expand target to 30-40s"
        why: "Research showed high demand in 40s"

    notes: "Additional findings, free-form"

  phases:                     # Phase DAG
    - id: research
      name: "Research"
      status: pending         # pending / in_progress / done
      depends_on: []
      gate: "Router reviews research results"

    - id: strategy
      depends_on: [research]
      gate: "User confirmation (L1)"

    - id: content
      depends_on: [strategy]
      gate: "Router quality check"

    - id: launch
      depends_on: [content]
      gate: "User final approval"
```

### 8.2 Phase DAG Rules

1. **A phase cannot start until all `depends_on` phases are `done`**
2. **A `gate` must be passed before the phase is marked `done`**
3. Gates respect the project's autonomy level:
   - L1: User must confirm every gate
   - L2: Only strategic gates need user confirmation
   - L3: Router passes gates autonomously (anomalies reported)
4. Router creates board tasks for the current phase only; next-phase tasks are created when the gate passes

### 8.3 Phase Transition Flow

```
Phase N tasks all done
  ↓
Router checks gate condition
  ↓
Gate requires user confirmation? (based on autonomy level)
  ├── Yes → Report to user, wait for approval
  └── No → Router approves
  ↓
Phase N marked done
  ↓
Phase N+1 tasks created on board
  (context.previous_results = Phase N result files)
  ↓
Workers woken for Phase N+1
```

### 8.4 Inter-Team Handoff

When one team's output is needed by another team:

**Handoff file** (`handoffs/{project}_{from}_{to}.yaml`):

```yaml
handoff:
  id: ho_001
  project: product_x
  from_team: design
  to_team: dev
  status: pending             # pending → accepted → completed
  description: "Implement based on design team's wireframes"
  deliverables:
    - results/task_005_result.yaml
    - "G:/My Drive/Projects/product_x/wireframe.fig"
  notes: "Mobile-first implementation"
  created_at: "2026-03-29T16:00:00"
  accepted_at: null
  completed_at: null
```

**Handoff by autonomy level**:
- **L1**: User verbally bridges between teams
- **L2+**: Router creates handoff file + wakes other team's Router via send-keys

**Status tracking prevents lost handoffs**:
- Receiving Router sets `status: accepted` when it reads the handoff
- Receiving Router sets `status: completed` when deliverables are produced

---

## 9. Autonomy Model

### 9.1 Levels

| Level | Human Involvement | Use Case |
|-------|-------------------|----------|
| **L1** | User confirms every gate/decision | New projects, sensitive work |
| **L2** | User confirms strategic decisions only | Established projects with trust |
| **L3** | User notified only on anomalies | Routine, well-understood work |

### 9.2 Decision Types and Initial Levels

| Decision Type | Initial Level | Description |
|--------------|---------------|-------------|
| `quality_gate` | L1 | Quality check between phases |
| `phase_transition` | L1 | Moving to next phase |
| `strategy_choice` | L1 | Strategic direction decisions |
| `task_decompose` | L2 | How to break down tasks (Router decides) |
| `worker_assign` | L2 | Which Worker gets which task (Router decides) |
| `external_publish` | L1 | External publishing (**never promotes**) |

### 9.3 Promotion Rules

**L1 → L2**: Same decision type approved 3 consecutive times by user.
- Router writes promotion proposal to `status/{team}.yaml`
- User approves → `config.yaml` `decision_types` updated

**L2 → L3**: 10+ tasks completed without issues at L2.
- Same proposal mechanism

**Demotion**: User rejects any deliverable → immediate -1 level.
- Reason recorded in Memory MCP for future reference

### 9.4 Always-Ask Override

Regardless of autonomy level, these always require user confirmation:
- Budget-related decisions
- External publishing or sending
- Changes to existing policies

### 9.5 Decision Flow

```
Decision point reached
  ↓
Check config.yaml decision_types for this type
  ↓
In always_ask list? → Yes → Ask user (regardless of level)
  ↓ No
Current level ≥ L2? → Yes → Router decides autonomously
  ↓ No (L1)
Ask user for confirmation
```

---

## 10. Skill Proposal System

### 10.1 Discovery (Worker)

Every Worker result file MUST include a `skill_candidate` section:

```yaml
skill_candidate:
  found: true                 # or false
  name: "seo-keyword-check"
  description: "Analyze article SEO keyword density and suggest improvements"
  reason: "Same pattern executed 3 times"
```

### 10.2 Evaluation (Router)

Router evaluates based on criteria in `config.yaml`:

| Criterion | Propose? |
|-----------|----------|
| Usable by other teams | Yes |
| Same pattern 2+ times | Yes |
| Automation stabilizes quality | Yes |
| One-time special case | No → reject |

### 10.3 Proposal File (`skill-proposals/{sp_id}.yaml`)

```yaml
proposal:
  id: sp_001
  name: "seo-keyword-check"
  description: "Analyze article SEO keyword density and suggest improvements"
  proposed_by: article/worker_2
  evaluated_by: article/router
  task_id: task_015
  reason: "Same procedure 3 times. Automation stabilizes quality."
  cross_team: true            # Useful beyond originating team
  status: pending             # pending / approved / rejected
  created_at: "2026-03-29T15:00:00"
```

### 10.4 Approval Flow

```
Worker reports skill_candidate: found: true
  ↓
Router evaluates against criteria
  ↓
Router creates skill-proposals/{sp_id}.yaml
  ↓
Router adds to status/{team}.yaml → skill_proposals section
  ↓
Dashboard auto-sync updates Sheets (Skills tab)
  ↓
User reviews and approves/rejects
  ↓
Approved → Create global skill in ~/.claude/skills/
```

---

## 11. Quality Gates

### 11.1 Review Tiers

| Priority | Review Method |
|----------|--------------|
| **high** | `/review` skill with `context: fork` (independent sub-agent) |
| **medium** | Worker self-review only (trusted) |
| **low** | Worker self-review only (trusted) |

### 11.2 `/review` Skill Execution

For high-priority tasks:
1. Router invokes `/review results/{task_id}_result.yaml`
2. The skill runs in `context: fork` — an independent sub-agent with its own context
3. Result: OK → proceed to next phase
4. Result: NG → Router creates a fix task on the board with the review feedback

### 11.3 Worker Self-Review Checklist

Before writing result, every Worker must verify:
- All completion criteria in task description are met
- Output quality is sufficient for the domain
- No typos, obvious errors, or inconsistencies

---

## 12. Context Management

### 12.1 Worker Context Threshold

Workers monitor their context usage via the Claude Code status line. When usage exceeds **50%**, the following protocol triggers:

```
Worker detects 50%+ context usage
  ↓
1. Stop at a natural breakpoint
2. Save partial progress to result file:
     status: blocked
     result.progress.completed: [what's done]
     result.progress.remaining: [what's left]
     result.deliverables: [partial outputs]
3. Update board: status: blocked
4. Notify Router via send-keys
5. WAIT (Router will send /clear)
```

### 12.2 Router /clear Protocol

```
Router receives 50% report from Worker
  ↓
1. Read Worker's partial result
2. Send /clear to Worker:
     psmux send-keys -t {session}:workers.{N} '/clear'
     psmux send-keys -t {session}:workers.{N} Enter
3. Verify /clear completed (capture-pane for prompt)
4. Create continuation task on board:
     - Include partial result in context.previous_results
     - Description covers remaining work only
5. Wake Worker for the new task
```

### 12.3 /clear Recovery (Worker)

After receiving /clear, the Worker restarts with minimal context:

```
1. Read worker.md (instructions)
2. Get @agent_id and @team_name via psmux display-message
3. Read teams/{team}.yaml
4. Read boards/{team}.yaml
5. Find assigned/pending task → resume from Step 1
6. No task → stop and wait
```

### 12.4 Post-Task /clear

Config option `cost.clear_after_task: true` means Workers should `/clear` after completing each task to free context for the next task. This is a cost optimization.

---

## 13. Knowledge & Memory Bloat Mitigation

This section addresses the critical concern of **unbounded growth** in two storage layers:
1. **Project knowledge** (`projects/{id}.yaml` → `knowledge` section)
2. **Memory MCP** (`memory/swarm_memory.jsonl`)

Both grow over time as projects accumulate decisions, insights, and preferences. Without mitigation, they become too large for agents to efficiently process.

### 13.1 Project Knowledge Bloat

**Problem**: The `knowledge.decisions[]` and `knowledge.notes` fields in project YAML files grow with every completed task. Eventually, a project file becomes too large for Workers to read efficiently, and most historical entries become irrelevant to current tasks.

**Mitigation Strategy: Tiered Knowledge Architecture**

```
Tier 1: Active Knowledge (in project YAML)
  └── Current decisions, active constraints, recent insights
  └── Size limit: ~50 entries in decisions[]
  └── Always loaded by Workers

Tier 2: Archived Knowledge (projects/{id}_archive.yaml)
  └── Historical decisions, superseded strategies, old notes
  └── Referenced only when explicitly needed
  └── Router moves entries here during phase transitions

Tier 3: Summarized Knowledge (in knowledge.summary field)
  └── Router-generated 5-10 line digest of archived knowledge
  └── Included in project YAML for quick context
```

**Archival Rules (Router responsibility)**:

| Trigger | Action |
|---------|--------|
| `decisions[]` exceeds 50 entries | Archive oldest 30 to `{id}_archive.yaml` |
| Phase completes | Review knowledge; archive phase-specific entries |
| Decision is superseded | Move old decision to archive, keep new one |
| Project pauses/completes | Archive all except essential constraints |

**Archival Format**:

```yaml
# projects/product_x_archive.yaml
archived_knowledge:
  archived_at: "2026-03-29T15:00:00"
  entries:
    - original_date: "2026-01-15"
      type: decision
      what: "Initial pricing at ¥3,000/mo"
      why: "Competitive entry point"
      superseded_by: "Pricing updated to ¥4,500/mo (2026-03-01)"
    - original_date: "2026-02-01"
      type: note
      content: "Early research findings on competitor landscape"
```

**Knowledge Extraction for Workers**:

Router does NOT give Workers the entire `knowledge` section. Instead:
- Router extracts ONLY the entries relevant to the current task
- Places them in `context.knowledge` on the task
- Workers never read the full project YAML directly

### 13.2 Memory MCP Bloat

**Problem**: Memory MCP (`memory/swarm_memory.jsonl`) accumulates observations across all sessions. Over time, it fills with stale preferences, outdated project insights, and redundant entries.

**Mitigation Strategy: Lifecycle-Based Cleanup**

**What to store** (from `config.yaml`):
- User preferences (tone, style, policy)
- Cross-project reusable insights
- Autonomy promotion/demotion history
- Skill proposal approval/rejection reasons

**What NOT to store**:
- Task details (live in board YAML)
- File contents (can be re-read)
- In-progress task status (live on board)
- Project-specific knowledge (lives in project YAML)

**Cleanup Rules**:

| Rule | Trigger | Action |
|------|---------|--------|
| **Deduplication** | Before writing new observation | Check if equivalent observation exists; skip if redundant |
| **Supersession** | User changes preference | Remove old preference, write new one (not append) |
| **Project completion** | Project marked `done` | Review project-specific memories; delete transient ones, keep generalizable insights |
| **Periodic review** | Every 10 project completions or monthly | Router reviews all memories; remove obsolete entries |
| **Scope tagging** | On every write | Tag with scope: `global` (keeps forever) or `project:{id}` (reviewable on project end) |

**Memory Entry Best Practices**:

```
# GOOD: Specific, actionable, tagged
Entity: user_preferences
Observation: "Prefers bullet points over paragraphs in reports"
Scope: global

# GOOD: Scoped to project, reviewable
Entity: project_product_x
Observation: "Client requires 48h review cycle before publishing"
Scope: project:product_x

# BAD: Vague, redundant
Entity: general
Observation: "Things are going well"
→ Don't store this.

# BAD: Already in YAML
Entity: task_info
Observation: "task_015 is assigned to worker_2"
→ This is on the board. Don't duplicate.
```

**Memory Size Monitoring**:

Router should periodically check memory size:
```
mcp__memory__read_graph()
→ If entity count > 100 or total observations > 500
→ Trigger cleanup review
→ Remove project-scoped entries for completed projects
→ Merge duplicate observations
→ Report cleanup results to user
```

### 13.3 Result File Cleanup

**Problem**: `results/` accumulates result files from every completed task indefinitely.

**Mitigation**:
- After a phase completes and its results are consumed by the next phase, result files become archival
- Router moves consumed results to `results/archive/` at phase transitions
- Archive can be periodically purged (user decision)
- Active results (current phase) remain in `results/`

### 13.4 Board Cleanup

**Problem**: `boards/{team}.yaml` grows with completed task entries.

**Mitigation**:
- When `-Clean` flag is used on deploy, boards are backed up and reset
- Router should periodically prune `status: done` entries older than 7 days
- Keep only `pending`, `assigned`, `blocked`, and recently `done` tasks on the board
- Pruned entries go to `logs/board_archive_{team}_{date}.yaml`

### 13.5 Bloat Mitigation Summary

| Storage | Growth Source | Mitigation | Responsible |
|---------|-------------|------------|-------------|
| Project knowledge | Task completions add decisions/notes | 3-tier archival (50-entry cap) | Router |
| Memory MCP | Session observations | Scope tagging + lifecycle cleanup | Router |
| Result files | Every task produces one | Archive after phase consumption | Router |
| Board files | Every task creates an entry | Prune done tasks > 7 days | Router |
| Handoff files | Inter-team coordination | Archive after `completed` status | Router |
| Skill proposals | Worker discoveries | Archive after `approved`/`rejected` | Router |

---

## 14. Google Workspace Integration

### 14.1 Google Sheets Dashboard

When `google.dashboard.enabled: true` and `spreadsheet_id` is set:

**Tool**: `gog` CLI (install: `brew install gogcli` → `gog auth add you@gmail.com`)

**Sheet Tabs**:

| Tab | Content | Update Trigger |
|-----|---------|---------------|
| Projects | Project overview | On project status change |
| Active | Currently active tasks | On task assignment/completion (clear-first write) |
| Completed | Finished tasks (append-only log) | On task completion |
| Skills | Skill proposals | On new proposal |

**Write Commands**:

```bash
# Append completed task to Completed tab
gog sheets write {spreadsheet_id} \
  --range "Completed!A:E" \
  --append \
  --data "{timestamp},{project},{team},{task_description},{result_summary}"

# Update Active tab (full replacement)
gog sheets write {spreadsheet_id} \
  --range "Active!A2:F" \
  --clear-first \
  --data "{active_tasks_as_csv}"
```

**Failure handling**: Sheets sync is non-fatal. If `gog` fails, local dashboard (`status.md`) is still updated. Error is noted in `status/{team}.yaml`.

### 14.2 Google Drive

Projects can reference Google Drive paths in `project.paths.drive`:

```yaml
paths:
  drive: "G:/My Drive/Projects/product_x"
  local: "C:/work/product_x"
```

- Google Drive Desktop app syncs Drive to local filesystem (e.g., `G:/` mount)
- Agents access Drive files as regular filesystem paths
- Handoff deliverables can reference Drive paths

---

## 15. Dashboard & Auto-Sync

### 15.1 Local Dashboard (`status.md`)

Auto-generated markdown file showing:
- Active tasks (team, task, worker, phase, started_at)
- Completed tasks today (time, team, task)

### 15.2 Team Status Files (`status/{team}.yaml`)

Each Router maintains its team's status file:

```yaml
team: dev
updated_at: "2026-03-29T15:30:00"

active:
  - id: task_003
    description: "API implementation"
    worker: worker_1
    phase: execute
    started_at: "2026-03-29T15:00:00"

completed_today:
  - id: task_001
    description: "Library research"
    completed_at: "2026-03-29T14:30:00"
    result_summary: "Recommends Express.js + Prisma"

blocked: []

skill_proposals:
  - id: sp_001
    name: "api-scaffold"
    status: pending
```

### 15.3 Background Watcher

Launched by `deploy.ps1` as a PowerShell background job:

1. Every **10 seconds**, check `status/*.yaml` for file changes (by LastWriteTime hash)
2. If changes detected:
   - Parse all status YAML files (simple regex-based, not full YAML parser)
   - Regenerate `status.md` with active/completed tables
   - Sync to Google Sheets (if configured)
3. This is the **only polling** in the entire system (justified: background job, minimal cost, no agent API calls)

---

## 16. Cost Control

### 16.1 Anti-Polling Policy

```yaml
cost:
  polling: forbidden
```

Agents must NEVER loop waiting for events. They:
- Write their output (result file, board update)
- Notify via send-keys
- **Stop completely**
- Resume only when woken by send-keys

### 16.2 Context Clearing

```yaml
cost:
  clear_after_task: true
```

Workers `/clear` after each task completion to free context. This prevents context accumulation across tasks and reduces token usage.

### 16.3 Opus Concurrency Limit

```yaml
cost:
  max_concurrent_opus: 4
```

In default mode (Sonnet workers), only Routers use Opus. This limits concurrent Opus instances to the number of deployed teams. In Battle mode, this limit is advisory — all agents are Opus.

### 16.4 Cost Optimization Summary

| Mechanism | Savings |
|-----------|---------|
| No polling | Eliminates idle API calls |
| /clear after task | Prevents context bloat, reduces token usage |
| Sonnet workers (default) | ~5x cheaper than Opus for execution tasks |
| Router thinking disabled (default) | Faster, cheaper dispatch |
| Deploy only needed teams | No idle teams consuming resources |
| 50% context threshold | Prevents expensive long-context calls |

---

## 17. Error Handling & Timeouts

### 17.1 Worker Failure

| Situation | Response |
|-----------|----------|
| Worker task fails | Router reassigns to a different Worker |
| Same task fails twice | Router reports to user (don't retry indefinitely) |
| Worker produces no result for 10 min | Router checks via `capture-pane`; if crashed, reassign |

### 17.2 Stale Task Detection

```yaml
timeouts:
  task_stale_minutes: 10
```

Router checks: if a task has been `assigned` for >10 minutes without completion, inspect the Worker pane. If the Worker is unresponsive or stuck, reassign.

### 17.3 Idle Worker Management

```yaml
timeouts:
  worker_idle_minutes: 30
```

Workers idle for >30 minutes should receive `/clear` to free resources. Router can do this proactively.

### 17.4 Sheets Sync Failure

Non-fatal. Local status files and `status.md` always update. Sheets errors are logged to `status/{team}.yaml` but do not block work.

### 17.5 Ambiguous Requests

Router must NOT guess when a request is unclear. Instead, ask the user for clarification.

---

## 18. Team Definitions

Teams are defined in `teams/{name}.yaml`. Each team has a domain scope (`what` it handles, `not` what it doesn't).

### 18.1 Pre-defined Teams

**dev** (Software Development):
- What: Feature implementation, bug fixes, API design, DB design, CI/CD, code review, refactoring, performance
- Not: UI/UX design (→ design), production ops (→ ops), business strategy (→ strategy)

**design** (UI/UX & Graphics):
- What: UI/UX design, wireframes, prototypes, graphic design, design systems
- Not: Implementation (→ dev), content writing (→ article)

**ops** (Operations):
- What: Server management, monitoring, incident response, infrastructure, security
- Not: Feature development (→ dev), business decisions (→ strategy)

**article** (Content & Articles):
- What: Blog posts, articles, SEO content, copywriting, editorial
- Not: Social media posts (→ sns), visual design (→ design)

**sns** (Social Media):
- What: Social media posts, engagement, scheduling, analytics, community management
- Not: Long-form content (→ article), ad campaigns (→ strategy)

**strategy** (Business Strategy):
- What: Market research, business planning, pricing, competitive analysis, growth strategy
- Not: Implementation (→ dev), content creation (→ article)

### 18.2 Adding a New Team

1. Create `teams/{name}.yaml`:
```yaml
name: marketing
session: marketing
description: "Ad campaigns, conversion optimization, A/B testing"

domain:
  what:
    - Ad campaign design
    - A/B test planning
    - Conversion analysis
  not:
    - Creative production (→ design)
    - Article writing (→ article)
```

2. Deploy: `./deploy.ps1 marketing`

Router and Worker instructions are **shared across all teams**. The team YAML defines domain expertise.

---

## 19. File Structure Reference

```
├── SPEC.md                          # This document
├── config.yaml                      # Global configuration
├── router.md                        # Router instructions (all teams)
├── worker.md                        # Worker instructions (all teams)
├── deploy.ps1                       # Deployment script (PowerShell)
├── architecture.md                  # Design overview
├── README.md                        # Quick start guide
│
├── teams/                           # Team domain definitions
│   ├── design.yaml
│   ├── design/CLAUDE.md             # Design domain knowledge
│   ├── dev.yaml
│   ├── dev/CLAUDE.md                # Dev domain knowledge
│   ├── ops.yaml
│   ├── ops/CLAUDE.md                # Ops domain knowledge
│   ├── article.yaml
│   ├── article/CLAUDE.md            # Article domain knowledge
│   ├── sns.yaml
│   ├── sns/CLAUDE.md                # SNS domain knowledge
│   ├── strategy.yaml
│   └── strategy/CLAUDE.md           # Strategy domain knowledge
│
├── projects/                        # Project definitions [runtime, git-ignored]
│   ├── _template.yaml               # Template for new projects
│   └── {project_id}.yaml            # Per-project: paths, teams, knowledge, phases
│
├── boards/                          # Task boards [runtime]
│   └── {team}.yaml                  # Per-team task list
│
├── results/                         # Task results [runtime]
│   ├── {task_id}_result.yaml        # Individual task results
│   └── archive/                     # Consumed results (post-phase)
│
├── handoffs/                        # Inter-team handoffs [runtime]
│   └── {project}_{from}_{to}.yaml
│
├── status/                          # Team status [runtime]
│   └── {team}.yaml                  # Each Router updates own file
│
├── status.md                        # Auto-generated dashboard [runtime]
│
├── skill-proposals/                 # Skill proposals [runtime]
│   └── {sp_id}.yaml
│
└── logs/                            # Backups and archives [runtime]
    ├── backup_{date}/               # Board backups from -Clean deploys
    └── board_archive_{team}_{date}.yaml  # Pruned board entries
```

**Legend**: `[runtime]` = created/populated at runtime, not in source control.

---

## Appendix A: Timestamp Rule

**All timestamps must be obtained via the `date` command. Never guess or hardcode.**

```bash
date "+%Y-%m-%dT%H:%M:%S"
```

This applies to: `created_at`, `completed_at`, `updated_at`, `archived_at`, and all other timestamp fields.

---

## Appendix B: Comparison with Shogun System

| Feature | Shogun | Swarm |
|---------|--------|-------|
| Structure | Fixed 3-tier (将軍→家老→足軽) | Independent domain teams |
| Sessions | 1 session, 10 agents | N sessions, 6 agents each |
| Planning | Karo (家老) manually plans | Router decides per task |
| Workers | Always 8 running | Deploy only what you need |
| Project focus | Single project | Multi-project via team composition |
| Theme | Samurai (mandatory) | Optional |
| Dashboard | Karo updates manually | Each Router + background auto-sync |
| External sync | Local only | Local + Google Sheets |
| Knowledge mgmt | Limited | Tiered archival with bloat mitigation |

---

## Appendix C: Quick Reference Card

```
DEPLOY:    ./deploy.ps1 dev article -Battle
CONNECT:   psmux attach -t dev
BOARDS:    boards/{team}.yaml
RESULTS:   results/{task_id}_result.yaml
STATUS:    status.md (auto) or status/{team}.yaml
HANDOFF:   handoffs/{project}_{from}_{to}.yaml
PROJECTS:  projects/{id}.yaml
SKILLS:    skill-proposals/{sp_id}.yaml → ~/.claude/skills/
CONFIG:    config.yaml
TEAMS:     teams/{name}.yaml
CLEANUP:   -Clean flag on deploy (backs up + resets boards)
```
