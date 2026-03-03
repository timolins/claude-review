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

if printf "dGVzdA==" | base64 --decode >/dev/null 2>&1; then
  BASE64_DECODE_CMD=(base64 --decode)
else
  BASE64_DECODE_CMD=(base64 -D)
fi

log_review() {
  printf "[review] %s\n" "$*" >&2
}

decode_b64() {
  local payload="${1:-}"
  if [ -z "$payload" ]; then
    return 0
  fi

  printf "%s" "$payload" | "${BASE64_DECODE_CMD[@]}"
}

sanitize_line() {
  local text="${1:-}"
  text="${text//$'\n'/ }"
  text="${text//$'\r'/ }"
  text="${text//$'\t'/ }"
  printf "%s" "$text"
}

shorten_line() {
  local text="$1"
  local max_len="${2:-140}"
  if [ "${#text}" -le "$max_len" ]; then
    printf "%s" "$text"
    return
  fi

  printf "%s..." "${text:0:max_len}"
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
  local event
  local printed_any_text=false
  local open_text_block=false
  local preview_buffer=""
  local preview_last_emit=0
  local result_error="false"
  local result_duration_ms=""
  local result_cost=""
  local result_text=""
  local saw_result=false
  local raw_line

  while IFS= read -r raw_line; do
    if [ -z "$raw_line" ]; then
      continue
    fi

    while IFS= read -r event; do
      if [ -z "$event" ]; then
        continue
      fi

      local event_kind payload
      if [[ "$event" == *$'\t'* ]]; then
        event_kind="${event%%$'\t'*}"
        payload="${event#*$'\t'}"
      else
        event_kind="$event"
        payload=""
      fi

      case "$event_kind" in
      INIT)
        local model_b64 session_id_b64 model session_id
        if [[ "$payload" == *$'\t'* ]]; then
          model_b64="${payload%%$'\t'*}"
          session_id_b64="${payload#*$'\t'}"
        else
          model_b64="$payload"
          session_id_b64=""
        fi

        model="$(decode_b64 "$model_b64" 2>/dev/null || true)"
        session_id="$(decode_b64 "$session_id_b64" 2>/dev/null || true)"
        if [ -n "$session_id" ]; then
          log_review "Session $session_id started (${model:-unknown model})."
        else
          log_review "Session started (${model:-unknown model})."
        fi
        ;;
      HOOK)
        local hook_name
        hook_name="$(decode_b64 "$payload" 2>/dev/null || true)"
        if [ -n "$hook_name" ]; then
          log_review "Hook: $(shorten_line "$(sanitize_line "$hook_name")" 140)"
        fi
        ;;
      TOOL_USE)
        local tool_name_b64 detail_b64 tool_name detail
        if [[ "$payload" == *$'\t'* ]]; then
          tool_name_b64="${payload%%$'\t'*}"
          detail_b64="${payload#*$'\t'}"
        else
          tool_name_b64="$payload"
          detail_b64=""
        fi

        tool_name="$(decode_b64 "$tool_name_b64" 2>/dev/null || true)"
        detail="$(decode_b64 "$detail_b64" 2>/dev/null || true)"
        detail="$(shorten_line "$(sanitize_line "$detail")" 140)"
        if [ -n "$detail" ]; then
          log_review "Claude is running ${tool_name}: $detail"
        else
          log_review "Claude is running ${tool_name}."
        fi
        ;;
      TOOL_DONE)
        local tool_error output_b64 tool_output preview
        if [[ "$payload" == *$'\t'* ]]; then
          tool_error="${payload%%$'\t'*}"
          output_b64="${payload#*$'\t'}"
        else
          tool_error="false"
          output_b64="$payload"
        fi

        tool_output="$(decode_b64 "$output_b64" 2>/dev/null || true)"
        preview="$(shorten_line "$(sanitize_line "$tool_output")" 140)"
        if [ -n "$preview" ]; then
          if [ "$tool_error" = "true" ]; then
            log_review "Tool output (error): $preview"
          else
            log_review "Tool output: $preview"
          fi
        fi
        ;;
      TEXT)
        local text
        text="$(decode_b64 "$payload" 2>/dev/null || true)"
        if [ -n "$text" ]; then
          printf "%s" "$text"
          printed_any_text=true
          open_text_block=true
          preview_buffer+="$text"

          local now should_emit_preview=false
          now="$(date +%s)"

          if [ "${#preview_buffer}" -ge "$REVIEW_LIVE_PREVIEW_MIN_CHARS" ]; then
            should_emit_preview=true
          fi

          if [ "$REVIEW_LIVE_PREVIEW_INTERVAL_SEC" -gt 0 ] && \
             [ "$preview_last_emit" -ne 0 ] && \
             [ $((now - preview_last_emit)) -ge "$REVIEW_LIVE_PREVIEW_INTERVAL_SEC" ] && \
             [ "${#preview_buffer}" -ge "$REVIEW_LIVE_PREVIEW_MIN_EMIT_CHARS" ]; then
            should_emit_preview=true
          fi

          if [[ "$preview_buffer" == *$'\n'* ]] && [ "${#preview_buffer}" -ge "$REVIEW_LIVE_PREVIEW_MIN_EMIT_CHARS" ]; then
            should_emit_preview=true
          fi

          if [ "$should_emit_preview" = true ]; then
            local preview
            preview="$(shorten_line "$(sanitize_line "$preview_buffer")" 220)"
            if [ -n "$preview" ]; then
              log_review "Draft: $preview"
            fi
            preview_buffer=""
            preview_last_emit="$now"
          fi
        fi
        ;;
      MESSAGE_STOP)
        if [ -n "$preview_buffer" ]; then
          local preview
          preview="$(shorten_line "$(sanitize_line "$preview_buffer")" 220)"
          if [ -n "$preview" ]; then
            log_review "Draft: $preview"
          fi
          preview_buffer=""
        fi

        if [ "$open_text_block" = true ]; then
          printf "\n"
          open_text_block=false
        fi
        ;;
      RESULT)
        local remaining result_text_b64
        saw_result=true
        remaining="$payload"

        if [[ "$remaining" == *$'\t'* ]]; then
          result_error="${remaining%%$'\t'*}"
          remaining="${remaining#*$'\t'}"
        else
          result_error="$remaining"
          remaining=""
        fi

        if [[ "$remaining" == *$'\t'* ]]; then
          result_duration_ms="${remaining%%$'\t'*}"
          remaining="${remaining#*$'\t'}"
        else
          result_duration_ms="$remaining"
          remaining=""
        fi

        if [[ "$remaining" == *$'\t'* ]]; then
          result_cost="${remaining%%$'\t'*}"
          result_text_b64="${remaining#*$'\t'}"
        else
          result_cost="$remaining"
          result_text_b64=""
        fi

        result_text="$(decode_b64 "$result_text_b64" 2>/dev/null || true)"
        ;;
      esac
    done < <(
      printf '%s\n' "$raw_line" | jq -Rr '
        def b64(value): (value // "" | @base64);
        (try fromjson catch empty) as $j |
        if $j.type == "system" and $j.subtype == "init" then
          "INIT\t" + b64($j.model) + "\t" + b64($j.session_id)
        elif $j.type == "system" and $j.subtype == "hook_started" then
          "HOOK\t" + b64($j.hook_name)
        elif $j.type == "assistant" then
          ($j.message.content[]? | select(.type == "tool_use") |
            "TOOL_USE\t" + b64(.name) + "\t" + b64(.input.description // .input.command))
        elif $j.type == "user" and ($j.tool_use_result != null) then
          "TOOL_DONE\t" +
          (((($j.message.content[]? | select(.type == "tool_result") | .is_error) // false) | tostring)) +
          "\t" +
          b64($j.tool_use_result.stdout // $j.tool_use_result.stderr)
        elif $j.type == "stream_event" and $j.event.type == "content_block_delta" and $j.event.delta.type == "text_delta" then
          "TEXT\t" + b64($j.event.delta.text)
        elif $j.type == "stream_event" and $j.event.type == "message_stop" then
          "MESSAGE_STOP"
        elif $j.type == "result" then
          "RESULT\t" +
          (($j.is_error // false) | tostring) + "\t" +
          (($j.duration_ms // "") | tostring) + "\t" +
          (($j.total_cost_usd // "") | tostring) + "\t" +
          b64($j.result)
        else
          empty
        end
      ' 2>/dev/null || true
    )
  done

  if [ "$open_text_block" = true ]; then
    printf "\n"
  fi

  if [ "$printed_any_text" = false ] && [ -n "$result_text" ]; then
    printf "%s\n" "$result_text"
  fi

  if [ "$saw_result" = false ]; then
    log_review "Stream parser did not receive a final result event."
    return 3
  fi

  if [[ "$result_duration_ms" =~ ^[0-9]+$ ]]; then
    local duration_seconds
    duration_seconds="$(awk "BEGIN { printf \"%.1f\", $result_duration_ms / 1000 }")"
    if [ -n "$result_cost" ] && [ "$result_cost" != "null" ]; then
      log_review "Claude finished in ${duration_seconds}s (cost \$${result_cost})."
    else
      log_review "Claude finished in ${duration_seconds}s."
    fi
  else
    log_review "Claude finished."
  fi

  if [ "$result_error" = "true" ]; then
    if [ -n "$result_text" ]; then
      log_review "Claude reported an error: $(shorten_line "$(sanitize_line "$result_text")" 180)"
    fi
    return 1
  fi
}

run_claude_prompt() {
  local prompt="$1"
  local length=${#prompt}
  if [ "$length" -gt "$MAX_PROMPT_CHARS" ]; then
    prompt="$(truncate_text "$prompt" "$MAX_PROMPT_CHARS" "review prompt")"
  fi

  local claude_flags=("${CLAUDE_FLAGS[@]}")

  if [ "$REVIEW_STREAM_JSON" = "1" ] && command -v jq >/dev/null 2>&1; then
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
    if [ "$REVIEW_STREAM_JSON" = "1" ] && ! command -v jq >/dev/null 2>&1; then
      log_review "jq not found; falling back to plain text output."
    fi
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

PROMPT="You are a coding peer — a second pair of eyes, not a gatekeeper. The developer who wrote this code is your equal. Your job is to think critically about the changes and start a discussion, not hand down a verdict.

## Your approach

- Raise concerns as questions and suggestions, not commands. \"Have you considered...\" not \"You must...\".
- Acknowledge when something is done well. Don't only point out problems.
- If something looks off, explain your reasoning. The author may have context you don't.
- Be open to being wrong. If the author pushes back with a good argument, concede.
- Focus on what actually matters: correctness, clarity, simplicity. Don't nitpick style or preferences.
- When suggesting an alternative, explain WHY it might be better, not just WHAT to change.
- BUT: don't be a pushover. If you see something genuinely wrong or messy, say so clearly. Push back when the author's reasoning doesn't hold up.
- Don't walk past broken windows. If the changes pile onto an already messy area, or make an existing problem worse, call it out. Suggest a refactor if the area would benefit from one — even if it's beyond the strict scope of the current changes. The codebase should get better over time, not worse.

## What to look at

### Does it achieve the goal?
- What is the stated/inferred goal?
- Do the changes accomplish it? Flag specific gaps if not.
- Edge cases or scenarios that might be missed?

### Could it be simpler or cleaner?
- Unnecessary complexity? Overcomplicated abstractions?
- Naming that's unclear or misleading?
- Dead code, unused imports, leftover debugging?
- Would a new team member understand this easily?
- Any security concerns?

### Opportunities to consolidate or restructure
- Duplication that could be extracted?
- Existing code in the codebase that could have been reused?
- Anything in the wrong file or layer?
- If you were to refactor the entire codebase, would it still look like this?
- Don't be afraid to suggest a refactor if the area would benefit from one — even if it's beyond the strict scope of the current changes. The codebase should get better over time, not worse.

## Context

Commit log:
$LOG

Branch diff stat ($BASE_BRANCH...HEAD):
$DIFF_STAT

Branch diff:
$DIFF_TRUNCATED"

if [ -n "$UNCOMMITTED_STAT" ] || [ -n "$STAGED_STAT" ]; then
  PROMPT="$PROMPT

Uncommitted changes stat:
$UNCOMMITTED_STAT

Uncommitted changes:
$UNCOMMITTED_TRUNCATED

Staged changes stat:
$STAGED_STAT

Staged changes:
$STAGED_TRUNCATED"
fi

if [ -n "$MESSAGE" ]; then
  PROMPT="$PROMPT

## Stated goal
$MESSAGE"
else
  PROMPT="$PROMPT

## Goal
Infer the goal from the commit messages and diff above."
fi

PROMPT="$PROMPT

## Output format

**Goal**: [what these changes are trying to do]

**Overall impression**: A few sentences on your read of the changes.

**Discussion points** (ordered by importance):
For each point:
- **file:line** — what you noticed, why it matters, and what you'd suggest. Frame as a question or suggestion where appropriate.

**Things done well**:
- Call out anything that's particularly clean, clever, or well-structured.

End with a clear summary: are these changes ready as-is, or are there things worth discussing before shipping?

Read additional files for context if the diff alone is not sufficient.

When diff content is truncated, prefer using the allowed git tools to inspect exact lines before making strong claims."

run_claude_prompt "$PROMPT"
