#!/usr/bin/env bash
# Distill — extract lessons from Claude Code session .jsonl files
#
# Usage:
#   distill.sh --list                   # show all known projects with paths
#   distill.sh                          # all projects
#   distill.sh --project multiterm-codex          # exact project name (basename)
#   distill.sh --project VENTURES/clark           # path fragment for disambiguation
#   distill.sh multiterm-codex          # legacy: partial slug match (kept for compat)
#   distill.sh --dry-run                # preview, no API calls, no writes
#   distill.sh --file path/to/file.jsonl
#
# Files:
#   Lessons content : /home/mp/Documents/Lessons/
#   State file      : ~/AI/Claude/myapps/Distill/.distill-state
#   Log file        : ~/AI/Claude/myapps/Distill/distill.log
#   Lock file       : /tmp/distill.lock

set -euo pipefail

LESSONS_DIR="/home/mp/Documents/Lessons"
PROJECTS_DIR="$HOME/.claude/projects"
DISTILL_DIR="$HOME/AI/Claude/myapps/Distill"
STATE_FILE="$DISTILL_DIR/.distill-state"
LOG_FILE="$DISTILL_DIR/distill.log"
LOCK_FILE="/tmp/distill.lock"
MARKER_PATTERNS="===PATTERNS==="
MARKER_INDEX="===INDEX-ENTRY==="
MODEL="haiku"
DRY_RUN=false
SPECIFIC_FILE=""
PROJECT_FILTER=""   # legacy slug substring
PROJECT_NAME=""     # --project: basename or path fragment
LIST_MODE=false

# Minimum session size to attempt distillation
MIN_LINES=50
# Skip sessions modified more recently than this (seconds) — likely still open
ACTIVE_THRESHOLD=1800

# ─── Logging ──────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --list)     LIST_MODE=true ;;
    --file)     shift; SPECIFIC_FILE="${1:-}" ;;
    --project)  shift; PROJECT_NAME="${1:-}" ;;
    --*)        echo "Unknown option: $1"; exit 1 ;;
    *)          PROJECT_FILTER="$1" ;;
  esac
  shift
done

# ─── Lock — prevent concurrent runs (e.g. two cron overlaps) ─────────────────

if [ "$DRY_RUN" = false ]; then
  if [ -f "$LOCK_FILE" ]; then
    log "SKIP — another Distill run is active (lock: $LOCK_FILE)"
    exit 0
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
fi

# ─── Project registry ────────────────────────────────────────────────────────
# Reads the cwd field from each project's .jsonl files — the ground truth for
# what directory the session actually ran in. Returns tab-separated lines:
#   slug <TAB> name <TAB> cwd <TAB> session_count <TAB> last_date

build_registry() {
  python3 - "$PROJECTS_DIR" <<'PYEOF'
import os, json, sys
from collections import defaultdict

projects_dir = sys.argv[1]
rows = []

for slug in sorted(os.listdir(projects_dir)):
    slug_dir = os.path.join(projects_dir, slug)
    if not os.path.isdir(slug_dir):
        continue
    sessions = []
    for fname in sorted(os.listdir(slug_dir)):
        if not fname.endswith('.jsonl'):
            continue
        fpath = os.path.join(slug_dir, fname)
        cwd = None
        last_ts = None
        try:
            with open(fpath) as f:
                for line in f:
                    try:
                        d = json.loads(line.strip())
                        if not cwd and d.get('cwd'):
                            cwd = d['cwd']
                        if d.get('timestamp'):
                            last_ts = d['timestamp'][:10]
                    except Exception:
                        pass
        except Exception:
            pass
        if cwd:
            sessions.append((last_ts or 'unknown', cwd))

    if not sessions:
        continue

    cwd = sessions[0][1]
    name = os.path.basename(cwd.rstrip('/'))
    last_date = max(s[0] for s in sessions)
    rows.append((last_date, slug, name, cwd, len(sessions)))

rows.sort(key=lambda r: r[0], reverse=True)
for last_date, slug, name, cwd, count in rows:
    print(f"{slug}\t{name}\t{cwd}\t{count}\t{last_date}")
PYEOF
}

# Print the registry as a human-readable table
cmd_list() {
  local registry
  registry=$(build_registry)

  # Detect ambiguous names
  local -A name_count
  while IFS=$'\t' read -r slug name cwd count last; do
    name_count["$name"]=$(( ${name_count["$name"]:-0} + 1 ))
  done <<< "$registry"

  printf "%-28s %-10s %-4s  %s\n" "PROJECT NAME" "LAST RUN" "SESS" "PATH"
  printf '%s\n' "$(printf '─%.0s' {1..72})"
  while IFS=$'\t' read -r slug name cwd count last; do
    local flag=""
    [[ ${name_count["$name"]:-0} -gt 1 ]] && flag=" *"
    printf "%-28s %-10s %-4s  %s%s\n" "$name" "$last" "$count" "$cwd" "$flag"
  done <<< "$registry"
  echo ""
  echo "* = ambiguous name — use a path fragment with --project to disambiguate"
  echo "    e.g.  distill.sh --project VENTURES/clark"
}

# Resolve --project <arg> to a list of matching slugs.
# Matches by: exact basename, then path fragment (substring of cwd).
# Exits with error if ambiguous and multiple cwd paths match.
resolve_project() {
  local arg="$1"
  local registry
  registry=$(build_registry)

  # Collect all matches
  local -a matched_slugs matched_names matched_cwds
  while IFS=$'\t' read -r slug name cwd count last; do
    if [[ "$name" == "$arg" ]] || [[ "$cwd" == *"$arg"* ]]; then
      matched_slugs+=("$slug")
      matched_names+=("$name")
      matched_cwds+=("$cwd")
    fi
  done <<< "$registry"

  local n=${#matched_slugs[@]}

  if [[ $n -eq 0 ]]; then
    echo "ERROR: No project matched '${arg}'" >&2
    echo "Run:  distill.sh --list" >&2
    exit 1
  fi

  if [[ $n -gt 1 ]]; then
    echo "ERROR: '${arg}' is ambiguous — matches ${n} projects:" >&2
    for i in "${!matched_slugs[@]}"; do
      echo "  ${matched_names[$i]}  →  ${matched_cwds[$i]}" >&2
    done
    echo "" >&2
    echo "Disambiguate with a path fragment, e.g.:" >&2
    echo "  distill.sh --project VENTURES/clark" >&2
    echo "  distill.sh --project github/clark" >&2
    exit 1
  fi

  # Exactly one match — print the slug for the caller
  echo "${matched_slugs[0]}"
}

# ─── State file helpers ───────────────────────────────────────────────────────
# State format (one line per processed session):
#   <uuid>  <mtime-epoch>  <line-count>  <project-slug>

state_key() {
  # uuid + mtime + linecount — if any change, session has grown and needs reprocessing
  local uuid="$1" mtime="$2" lines="$3"
  echo "${uuid}:${mtime}:${lines}"
}

already_processed() {
  local key="$1"
  [ -f "$STATE_FILE" ] && grep -qF "$key" "$STATE_FILE"
}

mark_processed() {
  local uuid="$1" mtime="$2" lines="$3" slug="$4"
  echo "$(state_key "$uuid" "$mtime" "$lines")  $slug" >> "$STATE_FILE"
}

# ─── Extract compaction summaries from a .jsonl file ─────────────────────────

extract_summaries() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            if d.get('type') != 'user':
                continue
            msg = d.get('message', {})
            if not isinstance(msg, dict):
                continue
            content = msg.get('content', '')
            if isinstance(content, list):
                text = next(
                    (b.get('text', '') for b in content
                     if isinstance(b, dict) and b.get('type') == 'text'),
                    ''
                )
            else:
                text = str(content)
            if 'This session is being continued from a previous conversation' in text:
                print(text)
                print('---END---')
        except Exception:
            pass
PYEOF
}

# ─── Extract session metadata from a .jsonl file ─────────────────────────────

get_meta() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import sys, json, os

file = sys.argv[1]
cwd = None
timestamps = []

with open(file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            if 'timestamp' in d:
                timestamps.append(d['timestamp'])
            if not cwd and d.get('cwd'):
                cwd = d['cwd']
        except Exception:
            pass

date  = timestamps[0][:10] if timestamps else 'unknown'
project_name = os.path.basename(cwd) if cwd else os.path.basename(os.path.dirname(file))

print(f"project_name:{project_name}")
print(f"date:{date}")
print(f"cwd:{cwd or 'unknown'}")
PYEOF
}

# ─── Safe filename from project name ─────────────────────────────────────────

safe_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' /' '--' | tr -cd 'a-z0-9-'
}

# ─── Build the distillation prompt ───────────────────────────────────────────

build_prompt() {
  local project_name="$1" date="$2" cwd="$3" summaries="$4"
  local existing_patterns
  existing_patterns=$(ls "$LESSONS_DIR/patterns/"*.md 2>/dev/null \
    | xargs -I{} basename {} | tr '\n' ' ' || echo "none yet")

  cat <<PROMPT
You are distilling a coding session into structured lesson files for long-term reference.

Session metadata:
- Project: $project_name
- Path: $cwd
- Date: $date

Session summary (auto-generated by Claude Code when the context window filled):
---
$summaries
---

Produce exactly three sections in this order:

━━━ SECTION 1 ━━━
A markdown detail file for decisions/${project_name}.md

Use these headings (skip any with nothing to say):
## What was built
## Key decisions (fork chosen + rationale — include what was rejected and why)
## Failures (root cause + exact fix — name files, functions, error text verbatim)
## Pending / next steps

Max ~60 lines. Be specific. Cut anything generic or obvious.

━━━ then this exact line ━━━
$MARKER_PATTERNS

━━━ SECTION 2 ━━━
Any techniques reusable across projects — not specific to $project_name but
applicable whenever someone uses the same library, OS feature, or pattern.

Existing patterns files: ${existing_patterns}

For each reusable pattern, write a block in this exact format:
TARGET: patterns/<filename>.md
---
## Pattern name

Short explanation + concrete code or command example.

---

If nothing is clearly reusable, write only: NONE

━━━ then this exact line ━━━
$MARKER_INDEX

━━━ SECTION 3 ━━━
1–3 one-line INDEX.md entries (for the decisions file and any new patterns files):
- [Short title](decisions/${project_name}.md) — one-line description

Output only the content. No preamble. No explanation. No outer code fences.
PROMPT
}

# ─── Append a pattern block to its target file ───────────────────────────────

_append_pattern() {
  local target="$1"; shift
  local target_file="$LESSONS_DIR/$target"
  local content
  content=$(printf '%s\n' "$@")

  if [ ! -f "$target_file" ]; then
    local title
    title=$(basename "$target" .md | tr '-' ' ' \
      | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
    printf '# %s Patterns\n\nAuto-extracted from sessions.\n\n---\n\n' \
      "$title" > "$target_file"
    log "  Created : $target_file"
  fi

  printf '\n%s\n' "$content" >> "$target_file"
  log "  Appended: $target_file"
}

# ─── Distill one .jsonl file ──────────────────────────────────────────────────

distill_file() {
  local file="$1"
  local uuid slug mtime lines key

  uuid=$(basename "$file" .jsonl)
  slug=$(basename "$(dirname "$file")")
  mtime=$(stat -c '%Y' "$file")
  lines=$(wc -l < "$file")

  # Skip sessions still being written (modified within ACTIVE_THRESHOLD seconds)
  local age=$(( $(date +%s) - mtime ))
  if [ "$age" -lt "$ACTIVE_THRESHOLD" ]; then
    log "  SKIP (active, ${age}s ago): $uuid"
    return 0
  fi

  # Skip sessions too short to contain a compaction summary
  if [ "$lines" -lt "$MIN_LINES" ]; then
    log "  SKIP (${lines} lines, below minimum ${MIN_LINES}): $uuid"
    return 0
  fi

  # Skip already-processed sessions (same uuid + mtime + lines)
  key=$(state_key "$uuid" "$mtime" "$lines")
  if already_processed "$key"; then
    log "  SKIP (already processed): $uuid"
    return 0
  fi

  local summaries meta project_name date cwd

  summaries=$(extract_summaries "$file")
  if [ -z "$summaries" ]; then
    log "  SKIP (no compaction summary): $uuid"
    # Still mark as processed so we don't recheck it every run
    [ "$DRY_RUN" = false ] && mark_processed "$uuid" "$mtime" "$lines" "$slug"
    return 0
  fi

  meta=$(get_meta "$file")
  project_name=$(echo "$meta" | grep "^project_name:" | cut -d: -f2-)
  date=$(echo "$meta"        | grep "^date:"         | cut -d: -f2-)
  cwd=$(echo "$meta"         | grep "^cwd:"          | cut -d: -f2-)

  log "  Project : $project_name  ($date)"
  log "  Summary : $(echo "$summaries" | wc -c) chars across $(echo "$summaries" | grep -c '---END---') compaction(s)"

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would call: claude -p --model $MODEL"
    echo "$summaries" | head -15
    return 0
  fi

  local filename detail_file prompt output
  filename=$(safe_name "$project_name")
  detail_file="$LESSONS_DIR/decisions/${filename}.md"

  log "  Calling claude -p --model $MODEL ..."
  prompt=$(build_prompt "$project_name" "$date" "$cwd" "$summaries")
  output=$(echo "$prompt" | claude -p --model "$MODEL" 2>/dev/null) || {
    log "  ERROR: claude -p failed — check API access"
    return 1
  }

  if [ -z "$output" ]; then
    log "  ERROR: Claude returned empty output"
    return 1
  fi

  # Split output on markers
  local detail_content patterns_content index_entries
  detail_content=$(echo "$output" | awk \
    "/^${MARKER_PATTERNS}\$/{stop=1} !stop{print}")
  patterns_content=$(echo "$output" | awk \
    "/^${MARKER_PATTERNS}\$/{in_p=1;next} /^${MARKER_INDEX}\$/{in_p=0} in_p{print}")
  index_entries=$(echo "$output" | awk \
    "/^${MARKER_INDEX}\$/{found=1;next} found{print}")

  # Write decisions file
  echo "$detail_content" > "$detail_file"
  log "  Written : $detail_file"

  # Handle patterns section
  local trimmed_patterns
  trimmed_patterns=$(echo "$patterns_content" | tr -d '[:space:]')
  if [ -n "$trimmed_patterns" ] && [ "$trimmed_patterns" != "NONE" ]; then
    local current_target="" block_lines=()
    while IFS= read -r line; do
      if [[ "$line" =~ ^TARGET:[[:space:]]*(patterns/[^[:space:]]+)$ ]]; then
        if [ -n "$current_target" ] && [ ${#block_lines[@]} -gt 0 ]; then
          _append_pattern "$current_target" "${block_lines[@]}"
          block_lines=()
        fi
        current_target="${BASH_REMATCH[1]}"
      elif [ -n "$current_target" ] && [ "$line" != "---" ]; then
        block_lines+=("$line")
      fi
    done <<< "$patterns_content"
    if [ -n "$current_target" ] && [ ${#block_lines[@]} -gt 0 ]; then
      _append_pattern "$current_target" "${block_lines[@]}"
    fi
  else
    log "  Patterns: none identified"
  fi

  # Append deduplicated index entries
  while IFS= read -r entry; do
    entry=$(echo "$entry" | sed 's/^[[:space:]]*//')
    [[ -z "$entry" || "${entry:0:1}" != "-" ]] && continue
    local link
    link=$(echo "$entry" | grep -o '([^)]*)' | head -1)
    if grep -qF "$link" "$LESSONS_DIR/INDEX.md" 2>/dev/null; then
      log "  Skipped (already indexed): $link"
    else
      echo "$entry" >> "$LESSONS_DIR/INDEX.md"
      log "  Indexed : $entry"
    fi
  done <<< "$index_entries"

  mark_processed "$uuid" "$mtime" "$lines" "$slug"
  log "  State   : recorded $uuid"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# ─── List mode (no lock needed) ───────────────────────────────────────────────

if [ "$LIST_MODE" = true ]; then
  cmd_list
  exit 0
fi

log "═══ Distill start (dry-run=$DRY_RUN, model=$MODEL)"

# ─── Single file mode ─────────────────────────────────────────────────────────

if [ -n "$SPECIFIC_FILE" ]; then
  log "File: $SPECIFIC_FILE"
  distill_file "$SPECIFIC_FILE"
  log "═══ Done"
  exit 0
fi

# ─── Resolve --project to a single slug ───────────────────────────────────────

RESOLVED_SLUG=""
if [ -n "$PROJECT_NAME" ]; then
  RESOLVED_SLUG=$(resolve_project "$PROJECT_NAME")
  log "Resolved --project '$PROJECT_NAME' → slug: $RESOLVED_SLUG"
fi

# ─── Walk all project directories ─────────────────────────────────────────────

found=0
processed=0
for project_dir in "$PROJECTS_DIR"/*/; do
  slug=$(basename "$project_dir")

  if [ -n "$RESOLVED_SLUG" ]; then
    # --project: exact slug match
    [ "$slug" != "$RESOLVED_SLUG" ] && continue
  elif [ -n "$PROJECT_FILTER" ]; then
    # legacy positional arg: substring slug match
    [[ "$slug" != *"$PROJECT_FILTER"* ]] && continue
  fi

  for jsonl_file in "$project_dir"*.jsonl; do
    [ -f "$jsonl_file" ] || continue
    found=$((found + 1))
    log "─── $(basename "$jsonl_file") in $slug"
    distill_file "$jsonl_file" && processed=$((processed + 1))
  done
done

log "═══ Done — $found session(s) examined, $processed processed"
