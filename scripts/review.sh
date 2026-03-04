#!/usr/bin/env bash
set -euo pipefail

SESSION_FILE=".review-session"
CONTINUE=false
MAX_PROMPT_CHARS="${REVIEW_MAX_PROMPT_CHARS:-180000}"
MAX_DIFF_CHARS="${REVIEW_MAX_DIFF_CHARS:-120000}"
MAX_WORKTREE_CHARS="${REVIEW_MAX_WORKTREE_CHARS:-40000}"
REVIEW_STREAM_JSON="${REVIEW_STREAM_JSON:-1}"
REVIEW_LIVE_PREVIEW_MIN_CHARS="${REVIEW_LIVE_PREVIEW_MIN_CHARS:-160}"
REVIEW_LIVE_PREVIEW_INTERVAL_SEC="${REVIEW_LIVE_PREVIEW_INTERVAL_SEC:-0}"
REVIEW_LIVE_PREVIEW_MIN_EMIT_CHARS="${REVIEW_LIVE_PREVIEW_MIN_EMIT_CHARS:-60}"

if [ "${1:-}" = "-c" ]; then
  CONTINUE=true
  shift
fi

MESSAGE="${1:-}"

if ! command -v claude >/dev/null 2>&1; then
  echo "Claude CLI not found in PATH." >&2
  exit 1
fi

CLAUDE_FLAGS=(--print --allowedTools "Read,Grep,Glob,Bash(git:*)")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STREAM_RENDERER_SCRIPT="$SCRIPT_DIR/render-stream.mjs"
PROMPT_TEMPLATE_FILE="$SCRIPT_DIR/review-prompt.md"
STREAM_RENDERER_CMD=()

if command -v bun >/dev/null 2>&1; then
  STREAM_RENDERER_CMD=(bun "$STREAM_RENDERER_SCRIPT")
elif command -v node >/dev/null 2>&1; then
  STREAM_RENDERER_CMD=(node "$STREAM_RENDERER_SCRIPT")
fi

log_review() {
  printf "[review] %s\n" "$*" >&2
}

truncate_text() {
  local text="$1"
  local limit="$2"
  local label="$3"
  local length=${#text}
  if [ "$length" -le "$limit" ]; then
    printf "%s" "$text"
    return
  fi

  printf "%s\n\n[truncated %s: showing first %s of %s chars]\n" \
    "${text:0:limit}" \
    "$label" \
    "$limit" \
    "$length"
}

render_stream_json() {
  if [ ! -f "$STREAM_RENDERER_SCRIPT" ]; then
    log_review "Stream renderer script not found at $STREAM_RENDERER_SCRIPT."
    return 4
  fi

  if [ ${#STREAM_RENDERER_CMD[@]} -eq 0 ]; then
    log_review "Neither bun nor node found; cannot render stream-json output."
    return 4
  fi

  log_review "Stream renderer: $(basename "${STREAM_RENDERER_CMD[0]}")."

  REVIEW_LIVE_PREVIEW_MIN_CHARS="$REVIEW_LIVE_PREVIEW_MIN_CHARS" \
    REVIEW_LIVE_PREVIEW_INTERVAL_SEC="$REVIEW_LIVE_PREVIEW_INTERVAL_SEC" \
    REVIEW_LIVE_PREVIEW_MIN_EMIT_CHARS="$REVIEW_LIVE_PREVIEW_MIN_EMIT_CHARS" \
    "${STREAM_RENDERER_CMD[@]}"
}

build_initial_review_prompt() {
  if [ ! -f "$PROMPT_TEMPLATE_FILE" ]; then
    log_review "Prompt template not found at $PROMPT_TEMPLATE_FILE."
    return 1
  fi

  local template
  template="$(cat "$PROMPT_TEMPLATE_FILE")"

  local uncommitted_section=""
  if [ -n "$UNCOMMITTED_STAT" ] || [ -n "$STAGED_STAT" ]; then
    uncommitted_section="
Uncommitted changes stat:
$UNCOMMITTED_STAT

Uncommitted changes:
$UNCOMMITTED_TRUNCATED

Staged changes stat:
$STAGED_STAT

Staged changes:
$STAGED_TRUNCATED"
  fi

  local goal_section
  if [ -n "$MESSAGE" ]; then
    goal_section="## Stated goal
$MESSAGE"
  else
    goal_section="## Goal
Infer the goal from the commit messages and diff above."
  fi

  template="${template//__COMMIT_LOG__/$LOG}"
  template="${template//__BASE_BRANCH__/$BASE_BRANCH}"
  template="${template//__DIFF_STAT__/$DIFF_STAT}"
  template="${template//__DIFF_TRUNCATED__/$DIFF_TRUNCATED}"
  template="${template//__UNCOMMITTED_SECTION__/$uncommitted_section}"
  template="${template//__GOAL_SECTION__/$goal_section}"

  printf "%s" "$template"
}

run_claude_prompt() {
  local prompt="$1"
  local length=${#prompt}
  if [ "$length" -gt "$MAX_PROMPT_CHARS" ]; then
    prompt="$(truncate_text "$prompt" "$MAX_PROMPT_CHARS" "review prompt")"
  fi

  local claude_flags=("${CLAUDE_FLAGS[@]}")

  if [ "$REVIEW_STREAM_JSON" = "1" ]; then
    claude_flags+=(--output-format=stream-json --include-partial-messages --verbose)
    log_review "Streaming Claude output (set REVIEW_STREAM_JSON=0 to disable)."
    set +e
    printf "%s" "$prompt" | claude "${claude_flags[@]}" | render_stream_json
    local stream_exit_code=$?
    set -e

    if [ "$stream_exit_code" -ne 0 ]; then
      log_review "Stream renderer failed (exit $stream_exit_code). Retrying once with plain output."
      local retry_flags=("${CLAUDE_FLAGS[@]}")

      if [ "$CONTINUE" = false ]; then
        local new_session_id skip_next arg
        new_session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
        local rebuilt_flags=()
        skip_next=false
        for arg in "${retry_flags[@]}"; do
          if [ "$skip_next" = true ]; then
            skip_next=false
            continue
          fi

          if [ "$arg" = "--session-id" ]; then
            skip_next=true
            continue
          fi

          rebuilt_flags+=("$arg")
        done

        rebuilt_flags+=(--session-id "$new_session_id")
        retry_flags=("${rebuilt_flags[@]}")
        echo "$new_session_id" > "$SESSION_FILE"
        log_review "Using fallback session $new_session_id for plain retry."
      fi

      printf "%s" "$prompt" | claude "${retry_flags[@]}"
    fi
  else
    printf "%s" "$prompt" | claude "${claude_flags[@]}"
  fi
}

if [ "$CONTINUE" = true ]; then
  if [ ! -f "$SESSION_FILE" ]; then
    echo "No review session found. Run a review first (without -c)." >&2
    exit 1
  fi

  SESSION_ID=$(cat "$SESSION_FILE")
  CLAUDE_FLAGS+=(-r "$SESSION_ID")

  FRESH_DIFF=$(git diff)
  FRESH_STAGED=$(git diff --cached)
  FRESH_CONTEXT=""
  if [ -n "$FRESH_DIFF" ] || [ -n "$FRESH_STAGED" ]; then
    FRESH_DIFF_TRUNCATED="$(truncate_text "$FRESH_DIFF" "$MAX_WORKTREE_CHARS" "uncommitted diff")"
    FRESH_STAGED_TRUNCATED="$(truncate_text "$FRESH_STAGED" "$MAX_WORKTREE_CHARS" "staged diff")"
    FRESH_CONTEXT="

Current uncommitted changes:
$FRESH_DIFF_TRUNCATED
$FRESH_STAGED_TRUNCATED"
  fi

  DEFAULT_MSG="I've made some updates. Thoughts?"
  PROMPT="${MESSAGE:-$DEFAULT_MSG}
${FRESH_CONTEXT}"

  run_claude_prompt "$PROMPT"
  exit 0
fi

SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
echo "$SESSION_ID" > "$SESSION_FILE"
CLAUDE_FLAGS+=(--session-id "$SESSION_ID")

BASE_BRANCH="main"
if ! git rev-parse --verify "$BASE_BRANCH" &>/dev/null; then
  BASE_BRANCH="master"
  if ! git rev-parse --verify "$BASE_BRANCH" &>/dev/null; then
    BASE_BRANCH="HEAD~5"
  fi
fi

DIFF_STAT=$(git diff "$BASE_BRANCH"...HEAD --stat 2>/dev/null || git diff "$BASE_BRANCH" HEAD --stat)
DIFF=$(git diff "$BASE_BRANCH"...HEAD 2>/dev/null || git diff "$BASE_BRANCH" HEAD)
UNCOMMITTED_STAT=$(git diff --stat)
UNCOMMITTED=$(git diff)
STAGED_STAT=$(git diff --cached --stat)
STAGED=$(git diff --cached)
LOG=$(git log "$BASE_BRANCH"...HEAD --oneline 2>/dev/null || git log "$BASE_BRANCH"..HEAD --oneline)

DIFF_TRUNCATED="$(truncate_text "$DIFF" "$MAX_DIFF_CHARS" "branch diff")"
UNCOMMITTED_TRUNCATED="$(truncate_text "$UNCOMMITTED" "$MAX_WORKTREE_CHARS" "uncommitted diff")"
STAGED_TRUNCATED="$(truncate_text "$STAGED" "$MAX_WORKTREE_CHARS" "staged diff")"

PROMPT="$(build_initial_review_prompt)"

run_claude_prompt "$PROMPT"
