# Distill

**Distill** automatically extracts reusable lessons from your [Claude Code](https://claude.ai/code) sessions and writes them into structured markdown files for long-term reference.

When Claude Code fills its context window, it writes a compaction summary of what happened in the session. Distill harvests those summaries, sends them to Claude (Haiku by default), and produces three kinds of output:

- **Decision files** — what was built, key forks taken, failures and their root causes, and next steps
- **Pattern files** — reusable techniques (library tricks, OS features, idioms) that apply across projects
- **INDEX.md entries** — one-liners that link to the above, giving you a searchable project memory at a glance

---

## How it works

1. Claude Code stores every session as a `.jsonl` file under `~/.claude/projects/<slug>/`
2. When the context window compresses, it writes a structured summary into the session file
3. `distill.sh` scans those files, extracts any compaction summaries, and skips sessions that are too short, still active, or already processed
4. It calls `claude -p --model haiku` (non-interactive print mode) with a structured prompt
5. The response is parsed and written to `decisions/`, `patterns/`, and `INDEX.md` inside your lessons directory

---

## Prerequisites

- **Claude Code CLI** — `claude` must be on your `$PATH` and authenticated  
  Install: https://docs.anthropic.com/claude-code
- **bash 4+** and standard POSIX tools (`python3`, `awk`, `stat`, `wc`)
- A writable lessons directory (see Configuration)

---

## Installation

```bash
git clone https://github.com/peers8862/distill.git
cd distill
chmod +x distill.sh
```

### Directory structure

Create the lessons directory with the expected subdirectories:

```bash
mkdir -p ~/Documents/Lessons/decisions
mkdir -p ~/Documents/Lessons/patterns
touch ~/Documents/Lessons/INDEX.md
```

---

## Configuration

Open `distill.sh` and update the path variables near the top:

```bash
LESSONS_DIR="/home/YOURNAME/Documents/Lessons"   # ← change to your lessons directory
PROJECTS_DIR="$HOME/.claude/projects"       # ← fine as-is (uses $HOME)
DISTILL_DIR="$HOME/AI/Claude/myapps/Distill" # ← change to where distill.sh lives
```

> **Note:** `LESSONS_DIR` is currently hardcoded with an absolute path. Update it to match your system before first use.

Other tunables at the top of the script:

| Variable           | Default | Description                                              |
|--------------------|---------|----------------------------------------------------------|
| `MODEL`            | `haiku` | Claude model used for distillation (`haiku`, `sonnet`)   |
| `MIN_LINES`        | `50`    | Minimum session length to attempt distillation           |
| `ACTIVE_THRESHOLD` | `1800`  | Skip sessions modified less than this many seconds ago   |

---

## Usage

```
distill.sh [OPTIONS] [PROJECT_SLUG]
```

### List all known projects

```bash
distill.sh --list
```

Prints a table of every project Claude Code has a session directory for, with last-run date, session count, and working directory path. Projects with ambiguous names (same basename, different paths) are flagged with `*`.

```
PROJECT NAME                 LAST RUN   SESS  PATH
────────────────────────────────────────────────────────────────────────
my-api                       2026-03-30 4     /home/mp/projects/my-api
clark                        2026-03-28 7     /home/mp/Documents/VENTURES/clark
```

### Distill all projects

```bash
distill.sh
```

### Distill a specific project

```bash
# By project name (basename of the working directory)
distill.sh --project my-api

# By path fragment — use this when a name is ambiguous
distill.sh --project VENTURES/clark
```

### Distill a single session file

```bash
distill.sh --file ~/.claude/projects/-home-mp-projects-my-api/abc123.jsonl
```

### Preview without writing anything

```bash
distill.sh --dry-run
distill.sh --dry-run --project my-api
```

`--dry-run` shows which sessions would be processed and prints the first 15 lines of each compaction summary. No Claude API calls are made and no files are written.

---

## Output structure

```
~/Documents/Lessons/
├── INDEX.md                  # Master index — one line per session distilled
├── decisions/
│   ├── my-api.md             # Per-project: what was built, decisions, failures
│   └── clark.md
└── patterns/
    ├── bash-arrays.md        # Reusable technique files
    └── sqlite-migrations.md
```

### `decisions/<project>.md`

Contains project-specific knowledge extracted from the session:

```markdown
## What was built
## Key decisions
## Failures
## Pending / next steps
```

### `patterns/<topic>.md`

Reusable techniques that apply across projects — library tricks, shell patterns, API idioms. Distill checks existing pattern files and appends new content to the appropriate file rather than creating duplicates.

### `INDEX.md`

One-line entries linking to all decisions and pattern files, deduplicated on each run:

```markdown
- [my-api: auth middleware rewrite](decisions/my-api.md) — replaced JWT library due to compliance requirements
- [Bash array iteration](patterns/bash-arrays.md) — safe pattern for iterating arrays with spaces in elements
```

---

## State tracking

Distill records each processed session in `~/.distill-state` (inside the Distill directory). The key is `uuid:mtime:linecount` — if a session file grows (the session was resumed and generated a new compaction), it will be re-processed automatically. Sessions that produce no compaction summary are still marked as seen so they are not rechecked on every run.

---

## Running automatically (cron)

To distill new sessions nightly:

```bash
crontab -e
```

Add:

```cron
0 2 * * * /path/to/distill.sh >> /path/to/distill.log 2>&1
```

Distill uses a lock file (`/tmp/distill.lock`) to prevent overlapping runs.

---

## Integrating with Claude Code

You can reference the lessons directory in your `~/.claude/CLAUDE.md` so Claude Code knows to consult it:

```markdown
## Cross-project knowledge base

A permanent lessons directory lives at: ~/Documents/Lessons/

Structure:
  INDEX.md          — master index, one line per lesson (load only when needed)
  patterns/         — reusable techniques safe to copy across projects
  decisions/        — forks in the road: what was chosen, what failed, and why

**Reading rule:** Do NOT load any file from /Documents/Lessons/ unless the user
asks about a pattern/decision, or unless you need it to avoid repeating a known
mistake.
```

And add a pointer to the distill script so Claude Code can invoke it:

```markdown
Distill script: ~/AI/Claude/myapps/Distill/distill.sh
```

---

## Troubleshooting

**"No compaction summary"** — the session did not trigger a context compression. Short sessions or sessions that ended before the context filled will not have a summary to distill. This is expected; the session is marked processed and skipped on future runs.

**"SKIP (active, Xs ago)"** — the session file was modified less than 30 minutes ago, meaning the session may still be open. Run again after closing the session.

**"claude -p failed"** — check that `claude` is authenticated (`claude --version` should succeed) and that you have API access.

**Empty output from Claude** — the model returned nothing. Try running with `--dry-run` first to inspect the summaries being sent.

---

## License

MIT
