# Distill

**Distill** automatically extracts reusable lessons from your [Claude Code](https://claude.ai/code) sessions and writes them into structured markdown files for long-term reference.

When Claude Code fills its context window, it writes a compaction summary of what happened in the session. Distill harvests those summaries — or falls back to sampling raw messages for shorter sessions — sends them to Claude (Haiku by default), and produces three kinds of output:

- **Decision files** — what was built, key forks taken, failures and their root causes, and next steps
- **Pattern files** — reusable techniques (library tricks, OS features, idioms) that apply across projects
- **INDEX.md entries** — one-liners that link to the above, giving you a searchable project memory at a glance

---

## How it works

1. Claude Code stores every session as a `.jsonl` file under `~/.claude/projects/<slug>/`
2. When the context window compresses, it writes a structured summary into the session file
3. `distill.sh` scans those files, extracts compaction summaries (or samples raw messages as a fallback), and skips sessions that are too short, still active, or already processed
4. It calls `claude -p --model haiku` (non-interactive print mode) with a structured prompt
5. The response is parsed and written to `decisions/`, `patterns/`, and `INDEX.md` inside your lessons directory

Multi-session projects accumulate a chronological history — each new session is appended to the existing decisions file under a `## Session: YYYY-MM-DD` header rather than overwriting it.

---

## Prerequisites

- **Claude Code CLI** — `claude` must be on your `$PATH` and authenticated
- **bash 4+** and standard POSIX tools (`python3`, `awk`, `stat`, `wc`)
- A writable lessons directory (see Configuration)

---

## Installation

```bash
git clone https://github.com/<your-username>/distill.git
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

### Environment variable

Set `DISTILL_LESSONS_DIR` to point to your lessons directory:

```bash
export DISTILL_LESSONS_DIR="$HOME/Documents/Lessons"
```

### Config file

Create `$DISTILL_DIR/.distillrc` (a sourced shell file) to set persistent defaults:

```bash
# .distillrc — overrides defaults; CLI flags take priority over this file
LESSONS_DIR="$HOME/Documents/Lessons"
MODEL="haiku"
MIN_LINES=50
ACTIVE_THRESHOLD=1800
```

`DISTILL_DIR` is always the directory containing `distill.sh` — no hardcoded paths needed.

### Tunables

| Variable           | Default                          | Description                                              |
|--------------------|----------------------------------|----------------------------------------------------------|
| `DISTILL_LESSONS_DIR` | `$HOME/Documents/Lessons`     | Lessons output directory (env var or .distillrc)         |
| `MODEL`            | `haiku`                          | Claude model used for distillation                       |
| `MIN_LINES`        | `50`                             | Minimum session length to attempt distillation           |
| `ACTIVE_THRESHOLD` | `1800`                           | Skip sessions modified less than this many seconds ago   |

---

## Usage

```
distill.sh [OPTIONS] [PROJECT_SLUG]
```

### List all known projects

```bash
distill.sh --list
```

Prints a table of every project Claude Code has a session directory for, with last-run date, session count, and working directory path. Projects with ambiguous names are flagged with `*`.

```
PROJECT NAME                 LAST RUN   SESS  PATH
────────────────────────────────────────────────────────────────────────
my-api                       2026-03-30 4     /home/you/projects/my-api
clark                        2026-03-28 7     /home/you/VENTURES/clark
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
distill.sh --file ~/.claude/projects/-home-you-projects-my-api/abc123.jsonl
```

### Preview without writing anything

```bash
distill.sh --dry-run
distill.sh --dry-run --project my-api
```

`--dry-run` shows which sessions would be processed and prints the first 15 lines of extracted content. No Claude API calls are made and no files are written.

### Reprocess already-seen sessions

```bash
distill.sh --force
distill.sh --force --project my-api
```

Bypasses the state-file check and reprocesses matching sessions. Decisions files are appended (not overwritten) and pattern deduplication prevents doubled content.

### Override the model

```bash
distill.sh --model sonnet
distill.sh --model sonnet --project my-api
```

### Limit to recent sessions

```bash
distill.sh --since 2026-03-01
```

Skips session files whose mtime predates the given date. Useful for large machines with many old sessions.

### Search the lessons corpus

```bash
distill.sh --search "websocket"
distill.sh --search "migration"
```

Greps all `.md` files in the lessons directory and prints matching lines with file context.

```
=== patterns/postgres-outbox-pattern.md ===
12:The outbox pattern ensures atomic delivery with no risk of lost messages...

─── 1 file(s) matched
```

---

## Output structure

```
~/Documents/Lessons/
├── INDEX.md                  # Master index — one line per project/pattern
├── decisions/
│   ├── my-api.md             # Per-project: what was built, decisions, failures
│   └── clark.md              # Multi-session projects append under ## Session headers
└── patterns/
    ├── bash-arrays.md        # Reusable technique files
    └── sqlite-migrations.md
```

### `decisions/<project>.md`

Contains project-specific knowledge. The first session creates the file; subsequent sessions append under a dated separator:

```markdown
## What was built
## Key decisions
## Failures
## Pending / next steps

---

## Session: 2026-03-28

## What was built
...
```

### `patterns/<topic>.md`

Reusable techniques that apply across projects. Distill checks for duplicate `##` headings before appending, so re-running with `--force` won't duplicate existing content.

### `INDEX.md`

One-line entries linking to all decisions and pattern files. Existing entries are updated in-place when a project is reprocessed — descriptions stay current without manual cleanup.

---

## State tracking

Distill records each processed session in `.distill-state` (inside the Distill directory). The key is `uuid:mtime:linecount` — if a session file grows (the session was resumed), it will be reprocessed automatically with the new content appended. Sessions that produce no extractable content are still marked so they are not rechecked on every run.

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

Reference the lessons directory in `~/.claude/CLAUDE.md` so Claude Code consults it automatically:

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

Distill script: ~/path/to/distill.sh
```

---

## Troubleshooting

**"no content extractable"** — the session had neither a compaction summary nor meaningful text messages (e.g., very short session, all tool-use with no prose). This is expected and the session is marked processed.

**"SKIP (active, Xs ago)"** — the session file was modified less than 30 minutes ago, meaning the session may still be open. Run again after closing it or increase `ACTIVE_THRESHOLD`.

**"claude -p failed"** — check that `claude` is authenticated (`claude --version` should succeed) and that you have API access.

**Decisions file not updating** — if you want to regenerate output for an already-processed session, use `--force`.

---

## License

MIT
