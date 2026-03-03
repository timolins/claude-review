---
name: claude-review
description: Start a code discussion with Claude as a peer reviewer via the CLI. Intended to be called by other AI agents (Codex, Cursor, etc.) after completing their work.
argument-hint: "[goal or context for the changes]"
disable-model-invocation: true
---

# Peer Code Discussion via Claude CLI

After completing your work, start a code discussion with Claude as a peer. Claude will raise questions and suggestions about your changes. You can push back, disagree, or explain your reasoning — the goal is to reach consensus on the best approach together.

## Usage

### Start a discussion

```bash
~/.agents/skills/claude-review/scripts/review.sh "description of what the changes should accomplish"
```

Or without a goal (Claude infers from commits):

```bash
~/.agents/skills/claude-review/scripts/review.sh
```

### Continue the conversation

Push back, explain your reasoning, or ask Claude to look at updates:

```bash
~/.agents/skills/claude-review/scripts/review.sh -c "I did it this way because X, what do you think?"
~/.agents/skills/claude-review/scripts/review.sh -c "I disagree — extracting that would add complexity for no real gain"
~/.agents/skills/claude-review/scripts/review.sh -c "Good point, I've refactored it. How does this look now?"
~/.agents/skills/claude-review/scripts/review.sh -c "I see your concern but this is intentional because of Y"
```

The `-c` flag resumes the same session so Claude has full context of the discussion.

### Optional tuning (for very large diffs)

You can tune prompt/diff truncation via env vars:

```bash
REVIEW_MAX_PROMPT_CHARS=180000 REVIEW_MAX_DIFF_CHARS=120000 REVIEW_MAX_WORKTREE_CHARS=40000 ~/.agents/skills/claude-review/scripts/review.sh
```

This keeps the review responsive on large branches while still giving Claude enough context.

Live progress is enabled by default (Claude stream JSON is parsed and shown as it runs).  
Set `REVIEW_STREAM_JSON=0` to fall back to plain `claude --print` output:

```bash
REVIEW_STREAM_JSON=0 ~/.agents/skills/claude-review/scripts/review.sh
```

If stream parsing fails at runtime (for example, local renderer/jq issues), the script now auto-retries once in plain output mode so reviews still complete.

## How it works

1. First run: collects branch diff, uncommitted changes, and commit log. Sends to Claude in `--print --output-format=stream-json` mode (when available), surfaces live progress/tool activity, and saves the session ID to `.review-session`.
2. Follow-ups with `-c`: resumes that session via `claude -r <session-id>`, includes fresh diff if there are new changes, and continues the discussion.

## Important

Claude is set up as a peer, not an authority. It will:
- Raise concerns as questions, not commands
- Concede when you make a good counterargument
- Acknowledge things done well, not just flag problems

The goal is consensus on what's best — not blind compliance with every suggestion.
