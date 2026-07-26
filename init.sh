#!/usr/bin/env bash
# Installed by slate. Edit to add project-specific setup.
set -euo pipefail

echo "[init.sh] starting..."

# Since slate 1.6.0 all state lives under docs/slate/.
mkdir -p docs/slate/progress/subagents docs/slate/features

_create_if_missing() {
  local file="$1" header="$2"
  if [ ! -s "$file" ]; then
    printf '%s\n' "$header" > "$file"
    echo "[init.sh] created $file"
  fi
}

_create_if_missing "docs/slate/progress/current.md" "# Current work

_(none in flight)_"

_create_if_missing "docs/slate/progress/history.md" "# Session history
"

_create_if_missing "docs/slate/features/backlog.md" "# Backlog
"

_create_if_missing "docs/slate/features/in-progress.md" "# In progress
"

_create_if_missing "docs/slate/features/done.md" "# Done

<!-- FORBIDDEN to edit existing entries. Create a successor with Supersedes: FEAT-XXX. -->
"

# Detect tooling and run lightweight setup (non-fatal)
[ -f package.json ] && command -v node >/dev/null 2>&1 && \
  { echo "[init.sh] node project; npm install..."; npm install --silent 2>/dev/null || true; }

[ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1 && \
  { echo "[init.sh] rust project; cargo check..."; cargo check --quiet 2>/dev/null || true; }

[ -f go.mod ] && command -v go >/dev/null 2>&1 && \
  { echo "[init.sh] go project; go mod download..."; go mod download 2>/dev/null || true; }

# NOTE: slate <= 1.7.0 regenerated docs/slate/progress/codebase-map.md here on
# every SessionStart. Nothing ever read it -- no hook injected it, no skill
# referenced it, and .gitignore excluded it. Measured on a live project: 677
# lines rebuilt per start, zero readers. Removed in 1.8.0.

echo "[init.sh] OK"
