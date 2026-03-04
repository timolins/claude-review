#!/usr/bin/env node
import readline from "node:readline";

function parseIntEnv(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function toText(value) {
  return typeof value === "string" ? value : "";
}

function sanitizeLine(text) {
  return text.replace(/[\n\r\t]+/g, " ");
}

function shortenLine(text, maxLen = 140) {
  if (text.length <= maxLen) return text;
  return `${text.slice(0, maxLen)}...`;
}

function logReview(message) {
  process.stderr.write(`[review] ${message}\n`);
}

const previewMinChars = parseIntEnv("REVIEW_LIVE_PREVIEW_MIN_CHARS", 160);
const previewIntervalSec = parseIntEnv("REVIEW_LIVE_PREVIEW_INTERVAL_SEC", 0);
const previewMinEmitChars = parseIntEnv("REVIEW_LIVE_PREVIEW_MIN_EMIT_CHARS", 60);

let printedAnyText = false;
let openTextBlock = false;
let previewBuffer = "";
let previewLastEmitSec = 0;

let sawResult = false;
let resultError = false;
let resultDurationMs = null;
let resultCost = null;
let resultText = "";

function emitPreview(force = false) {
  if (!previewBuffer) return;

  const nowSec = Math.floor(Date.now() / 1000);
  let shouldEmit = force;

  if (!shouldEmit && previewBuffer.length >= previewMinChars) {
    shouldEmit = true;
  }

  if (
    !shouldEmit &&
    previewIntervalSec > 0 &&
    previewLastEmitSec > 0 &&
    nowSec - previewLastEmitSec >= previewIntervalSec &&
    previewBuffer.length >= previewMinEmitChars
  ) {
    shouldEmit = true;
  }

  if (!shouldEmit && previewBuffer.includes("\n") && previewBuffer.length >= previewMinEmitChars) {
    shouldEmit = true;
  }

  if (!shouldEmit) return;

  const preview = shortenLine(sanitizeLine(previewBuffer), 220);
  if (preview) {
    logReview(`Draft: ${preview}`);
  }

  previewBuffer = "";
  previewLastEmitSec = nowSec;
}

function onTextDelta(text) {
  if (!text) return;

  process.stdout.write(text);
  printedAnyText = true;
  openTextBlock = true;

  previewBuffer += text;
  emitPreview(false);
}

function onMessageStop() {
  emitPreview(true);

  if (openTextBlock) {
    process.stdout.write("\n");
    openTextBlock = false;
  }
}

function onInit(msg) {
  const model = toText(msg.model) || "unknown model";
  const sessionId = toText(msg.session_id);
  if (sessionId) {
    logReview(`Session ${sessionId} started (${model}).`);
  } else {
    logReview(`Session started (${model}).`);
  }
}

function onHook(msg) {
  const hookName = toText(msg.hook_name);
  if (hookName) {
    logReview(`Hook: ${shortenLine(sanitizeLine(hookName), 140)}`);
  }
}

function onAssistantMessage(msg) {
  const content = Array.isArray(msg?.message?.content) ? msg.message.content : [];
  for (const item of content) {
    if (item?.type !== "tool_use") continue;

    const toolName = toText(item.name) || "tool";
    const detail = toText(item.input?.description || item.input?.command);
    if (detail) {
      logReview(`Claude is running ${toolName}: ${shortenLine(sanitizeLine(detail), 140)}`);
    } else {
      logReview(`Claude is running ${toolName}.`);
    }
  }
}

function onToolResult(msg) {
  const content = Array.isArray(msg?.message?.content) ? msg.message.content : [];
  const toolError = content.some((item) => item?.type === "tool_result" && item?.is_error === true);

  const output = toText(msg?.tool_use_result?.stdout || msg?.tool_use_result?.stderr);
  if (!output) return;

  const preview = shortenLine(sanitizeLine(output), 140);
  if (!preview) return;

  if (toolError) {
    logReview(`Tool output (error): ${preview}`);
  } else {
    logReview(`Tool output: ${preview}`);
  }
}

function onResult(msg) {
  sawResult = true;
  resultError = Boolean(msg?.is_error);
  resultText = toText(msg?.result);

  if (typeof msg?.duration_ms === "number" && Number.isFinite(msg.duration_ms)) {
    resultDurationMs = msg.duration_ms;
  }

  if (typeof msg?.total_cost_usd === "number" && Number.isFinite(msg.total_cost_usd)) {
    resultCost = msg.total_cost_usd;
  }
}

async function main() {
  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  for await (const rawLine of rl) {
    if (!rawLine) continue;

    let msg;
    try {
      msg = JSON.parse(rawLine);
    } catch {
      continue;
    }

    if (msg?.type === "system" && msg?.subtype === "init") {
      onInit(msg);
      continue;
    }

    if (msg?.type === "system" && msg?.subtype === "hook_started") {
      onHook(msg);
      continue;
    }

    if (msg?.type === "assistant") {
      onAssistantMessage(msg);
      continue;
    }

    if (msg?.type === "user" && msg?.tool_use_result) {
      onToolResult(msg);
      continue;
    }

    if (
      msg?.type === "stream_event" &&
      msg?.event?.type === "content_block_delta" &&
      msg?.event?.delta?.type === "text_delta"
    ) {
      onTextDelta(toText(msg.event.delta.text));
      continue;
    }

    if (msg?.type === "stream_event" && msg?.event?.type === "message_stop") {
      onMessageStop();
      continue;
    }

    if (msg?.type === "result") {
      onResult(msg);
      continue;
    }
  }

  emitPreview(true);

  if (openTextBlock) {
    process.stdout.write("\n");
    openTextBlock = false;
  }

  if (!printedAnyText && resultText) {
    process.stdout.write(`${resultText}\n`);
  }

  if (!sawResult) {
    logReview("Stream parser did not receive a final result event.");
    process.exit(3);
  }

  if (Number.isFinite(resultDurationMs)) {
    const seconds = (resultDurationMs / 1000).toFixed(1);
    if (Number.isFinite(resultCost)) {
      logReview(`Claude finished in ${seconds}s (cost $${resultCost}).`);
    } else {
      logReview(`Claude finished in ${seconds}s.`);
    }
  } else {
    logReview("Claude finished.");
  }

  if (resultError) {
    if (resultText) {
      logReview(`Claude reported an error: ${shortenLine(sanitizeLine(resultText), 180)}`);
    }
    process.exit(1);
  }
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  logReview(`Stream renderer crashed: ${message}`);
  process.exit(5);
});
