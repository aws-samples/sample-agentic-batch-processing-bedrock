#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Worker: processes ONE work item per container invocation.
#
# The whole wrapper is this script. It fetches the item from S3 to a local path,
# checks the ledger, runs the agent CLI, parses usage out of the result, uploads
# the output, and records the outcome. The agent itself is unmodified: it sees a
# local file, exactly as it would on a laptop.

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================
# Injected by the Batch job definition. No defaults for the resource names: a
# missing value must fail loudly rather than silently target the wrong account.
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required (set by the Batch job definition)}"
DYNAMODB_TABLE="${DYNAMODB_TABLE:?DYNAMODB_TABLE is required (set by the Batch job definition)}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required (set by the Batch job definition)}"
PLUGIN_DIR="${PLUGIN_DIR:-/opt/agent-logic}"
WORK_DIR="${WORK_DIR:-/work}"
INPUT_PREFIX="${INPUT_PREFIX:-input}"
OUTPUT_PREFIX="${OUTPUT_PREFIX:-output}"
INPUT_EXTENSION="${INPUT_EXTENSION:-txt}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

ITEM_START_TIME=""

# ============================================================
# LOGGING
# ============================================================
# One structured line per stage transition. Every CloudWatch Logs Insights query
# in the dashboard depends on these field names, so choose them before building
# the dashboard rather than after.
log_json() {
    local stage="$1" status="$2"; shift 2
    local message="$*"
    local elapsed=0
    [ -n "$ITEM_START_TIME" ] && elapsed=$(( $(date +%s) - ITEM_START_TIME ))
    printf '{"timestamp":"%s","item_id":"%s","stage":"%s","status":"%s","elapsed_seconds":%d,"message":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ITEM_ID:-unknown}" "$stage" "$status" "$elapsed" "$message"
}

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ============================================================
# TERMINAL FAILURE HANDLING
# ============================================================
# An item stuck in a non-terminal state is worse than an item that failed: it is
# indistinguishable from work in progress, so nothing alerts and the batch looks
# healthy. This function is what makes the batch countable, so it is built to
# survive its own failure modes:
#
#   1. The error payload is built with a real JSON serializer, not string
#      interpolation. Model output and stack traces contain quotes and newlines
#      that produce malformed JSON and a silently failed status write.
#   2. The write is retried, and whether it succeeded is logged.
#   3. If the detailed write fails anyway, a bare status flip still runs, so the
#      item never stays in PROCESSING.
mark_error() {
    local item="$1" duration="$2" raw_message="$3"
    local errfile="${WORK_DIR}/_err_${item}.json"
    # STDERR_LOG may not exist yet if we fail before the agent step (an S3 404,
    # say). Under `set -u` an unbound reference would abort this handler and
    # leave the item in PROCESSING, so default it.
    local stderr_log="${STDERR_LOG:-/dev/null}"

    ITEM_ERR="$item" DUR_ERR="$duration" MSG_ERR="$raw_message" \
    TS_ERR="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    python3 - "$errfile" <<'PYEOF' 2>/dev/null
import json, os, sys
msg = os.environ.get("MSG_ERR", "")[:900]
payload = {
    ":status":   {"S": "ERROR"},
    ":end_ts":   {"S": os.environ.get("TS_ERR", "")},
    ":duration": {"N": str(os.environ.get("DUR_ERR") or "0")},
    ":error":    {"S": msg or "No details"},
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
PYEOF

    local wrote="false"
    if [ -f "$errfile" ]; then
        for attempt in 1 2 3; do
            if aws dynamodb update-item \
                --table-name "$DYNAMODB_TABLE" \
                --key "{\"item_id\":{\"S\":\"${item}\"}}" \
                --update-expression "SET processing_status = :status, end_timestamp = :end_ts, duration_seconds = :duration, error_message = :error" \
                --expression-attribute-values "file://${errfile}" \
                --region "$AWS_REGION" 2>>"$stderr_log"; then
                wrote="true"; break
            fi
            sleep $(( attempt * 2 ))
        done
    fi

    if [ "$wrote" = "true" ]; then
        log_json "ledger_error" "success" "ERROR recorded"
    else
        aws dynamodb update-item \
            --table-name "$DYNAMODB_TABLE" \
            --key "{\"item_id\":{\"S\":\"${item}\"}}" \
            --update-expression "SET processing_status = :status" \
            --expression-attribute-values '{":status":{"S":"ERROR"}}' \
            --region "$AWS_REGION" 2>>"$stderr_log" || true
        log_json "ledger_error" "failed" "Could not record full ERROR details"
    fi

    rm -f "$errfile" 2>/dev/null || true
}

# ============================================================
# PREFLIGHT
# ============================================================
for binary in aws claude python3; do
    if ! command -v "$binary" >/dev/null 2>&1; then
        log "ERROR: required binary not found: $binary"
        log_json "preflight" "failed" "Missing binary: $binary"
        exit 1
    fi
done

if [ ! -d "$PLUGIN_DIR" ]; then
    log "ERROR: agent logic directory not found: $PLUGIN_DIR"
    log_json "preflight" "failed" "Missing agent logic: $PLUGIN_DIR"
    exit 1
fi

COMMAND_FILE="${COMMAND_FILE:-${PLUGIN_DIR}/commands/analyze.md}"
if [ ! -f "$COMMAND_FILE" ]; then
    log "ERROR: command file not found: $COMMAND_FILE"
    log_json "preflight" "failed" "Missing command file: $COMMAND_FILE"
    exit 1
fi
log_json "preflight" "success" "Dependencies verified"

# ============================================================
# RESOLVE THE ITEM ID
# ============================================================
# Either an explicit ITEM_ID (single submission or a container override) or the
# array index, when submitted as an array job sized to the item count.
if [ -n "${ITEM_ID:-}" ]; then
    : # supplied directly
elif [ -n "${AWS_BATCH_JOB_ARRAY_INDEX:-}" ]; then
    ITEM_ID="$(printf "%s%03d" "${ARRAY_ITEM_PREFIX:-item-}" "$AWS_BATCH_JOB_ARRAY_INDEX")"
else
    log "ERROR: neither ITEM_ID nor AWS_BATCH_JOB_ARRAY_INDEX was provided"
    log_json "init" "failed" "No item ID"
    exit 1
fi

ITEM_START_TIME=$(date +%s)
# Define these up front so mark_error can reference them on any failure path.
LOCAL_INPUT="${WORK_DIR}/${ITEM_ID}.${INPUT_EXTENSION}"
RAW_OUTPUT="${WORK_DIR}/${ITEM_ID}-raw.jsonl"
LOCAL_RESULT="${WORK_DIR}/${ITEM_ID}-result.json"
STDERR_LOG="${WORK_DIR}/${ITEM_ID}-stderr.log"

log "item=${ITEM_ID} bucket=${S3_BUCKET} table=${DYNAMODB_TABLE} region=${AWS_REGION}"
log "agent CLI version: $(claude --version 2>/dev/null || echo unknown)"
log_json "init" "success" "Item resolved"

# ============================================================
# IDEMPOTENCY
# ============================================================
# Batch retries and operator re-submissions both replay items. Checking for a
# terminal status first makes re-running a batch safe and cheap.
#
# Note the constraint this imposes: with item_id as the sole key, processing the
# same item twice is impossible, so a run intended to compare two model
# configurations is silently skipped and hands back the original results. If you
# need that, add a run ID to the key or namespace the item IDs per run.
EXISTING_STATUS=$(aws dynamodb get-item \
    --table-name "$DYNAMODB_TABLE" \
    --key "{\"item_id\":{\"S\":\"${ITEM_ID}\"}}" \
    --projection-expression "processing_status" \
    --region "$AWS_REGION" \
    --output text --query 'Item.processing_status.S' 2>/dev/null || echo "NOT_FOUND")

if [ "$EXISTING_STATUS" = "SUCCESS" ]; then
    log "Item already processed. Exiting."
    log_json "idempotency" "skipped" "Already processed"
    exit 0
fi
log_json "idempotency" "success" "Not yet processed"

# ============================================================
# CLAIM THE ITEM
# ============================================================
aws dynamodb put-item \
    --table-name "$DYNAMODB_TABLE" \
    --item "{
        \"item_id\":{\"S\":\"${ITEM_ID}\"},
        \"processing_status\":{\"S\":\"PROCESSING\"},
        \"start_timestamp\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},
        \"model_used\":{\"S\":\"${ANTHROPIC_MODEL:-unspecified}\"},
        \"worker_job_id\":{\"S\":\"${AWS_BATCH_JOB_ID:-local}\"}
    }" \
    --region "$AWS_REGION"
log_json "ledger_claim" "success" "Marked PROCESSING"

# ============================================================
# FETCH THE INPUT
# ============================================================
S3_INPUT="s3://${S3_BUCKET}/${INPUT_PREFIX}/${ITEM_ID}.${INPUT_EXTENSION}"
if ! aws s3 cp "$S3_INPUT" "$LOCAL_INPUT" --region "$AWS_REGION"; then
    MESSAGE="Failed to download input from ${S3_INPUT}"
    log "ERROR: $MESSAGE"
    log_json "fetch" "failed" "$MESSAGE"
    mark_error "$ITEM_ID" "$(( $(date +%s) - ITEM_START_TIME ))" "$MESSAGE"
    exit 1
fi
log_json "fetch" "success" "Input downloaded"

# ============================================================
# RUN THE AGENT
# ============================================================
# Print mode with stream-json: the stream ends with a result event carrying token
# counts and a total cost for the run, so usage comes back as data instead of
# prose to parse. stdout and stderr go to separate files because diagnostic
# output on stderr would otherwise interleave with the JSON stream and corrupt it.
#
# Bounded retry with backoff covers transient conditions such as throttling under
# concurrency. Deterministic failures are not worth retrying, but they are also
# not distinguishable from here by exit code alone, so the attempt cap is low.
#
# The prompt is the body of the command file, not a slash-command invocation.
# Slash commands are an interactive-session feature: in print mode the CLI does
# not resolve them, and it does not fail either. It returns exit 0 with
# "Unknown command: /analyze" as the result and zero tokens, which is the worst
# possible shape for a batch job. Passing the body directly is both immune to
# that and independent of how any particular CLI names its commands.
AGENT_START=$(date +%s)
AGENT_OK=false
AGENT_EXIT=0

AGENT_PROMPT=$(COMMAND_FILE="$COMMAND_FILE" ARG="$LOCAL_INPUT" python3 - <<'PYEOF'
import os, re
text = open(os.environ["COMMAND_FILE"], encoding="utf-8").read()
# Strip YAML frontmatter, which is metadata for the CLI rather than prompt text.
match = re.match(r"^---\n.*?\n---\n", text, re.S)
body = text[match.end():] if match else text
arg = os.environ["ARG"]
print(body.replace("$ARGUMENTS", arg).replace("$1", arg).strip())
PYEOF
)

if [ -z "$AGENT_PROMPT" ]; then
    MESSAGE="Command file produced an empty prompt: ${COMMAND_FILE}"
    log "ERROR: $MESSAGE"
    log_json "agent" "failed" "$MESSAGE"
    mark_error "$ITEM_ID" 0 "$MESSAGE"
    exit 1
fi

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    [ "$attempt" -gt 1 ] && log "retry ${attempt}/${MAX_ATTEMPTS}"
    set +e
    claude -p "$AGENT_PROMPT" \
        --plugin-dir "$PLUGIN_DIR" \
        --permission-mode acceptEdits \
        --output-format stream-json \
        --verbose > "$RAW_OUTPUT" 2> "$STDERR_LOG"
    AGENT_EXIT=$?
    set -e
    if [ "$AGENT_EXIT" -eq 0 ]; then AGENT_OK=true; break; fi
    log_json "agent" "retry" "Attempt ${attempt} exited ${AGENT_EXIT}"
    [ "$attempt" -lt "$MAX_ATTEMPTS" ] && sleep $(( attempt * 10 - 5 ))
done

DURATION=$(( $(date +%s) - AGENT_START ))

if [ "$AGENT_OK" = false ]; then
    MESSAGE="Agent CLI exited ${AGENT_EXIT}"
    log "ERROR: $MESSAGE after ${DURATION}s"
    # Surface the real reason in CloudWatch. Without this the cause is lost.
    [ -s "$STDERR_LOG" ] && tail -20 "$STDERR_LOG" | sed 's/^/    /'
    DETAILS="$( [ -s "$STDERR_LOG" ] && tail -20 "$STDERR_LOG" | tr '\n' ' ' || echo "no stderr" )"
    log_json "agent" "failed" "$MESSAGE"
    mark_error "$ITEM_ID" "$DURATION" "${MESSAGE}: ${DETAILS}"
    rm -f "$LOCAL_INPUT" "$RAW_OUTPUT" "$LOCAL_RESULT" "$STDERR_LOG"
    exit 1
fi

if [ ! -s "$RAW_OUTPUT" ]; then
    MESSAGE="Agent produced no output"
    log "ERROR: $MESSAGE"
    log_json "agent" "failed" "$MESSAGE"
    mark_error "$ITEM_ID" "$DURATION" "$MESSAGE"
    rm -f "$LOCAL_INPUT" "$RAW_OUTPUT" "$LOCAL_RESULT" "$STDERR_LOG"
    exit 1
fi

log_json "agent" "success" "Completed in ${DURATION}s"

# ============================================================
# EXTRACT USAGE AND THE RESULT PAYLOAD
# ============================================================
# Parsed defensively across three shapes so it survives CLI output-format
# differences: a JSONL stream, a single result envelope, or a bare payload.
METRICS=$(RAW_FILE="$RAW_OUTPUT" RESULT_FILE="$LOCAL_RESULT" python3 - <<'PYEOF' 2>/dev/null || echo ""
import json, os, sys

raw_path, result_path = os.environ["RAW_FILE"], os.environ["RESULT_FILE"]

def pick(d, *keys):
    for k in keys:
        if d.get(k) is not None:
            return d[k]
    return 0

def usage_of(obj):
    u = obj.get("usage") or {}
    return (
        pick(obj, "total_cost_usd"),
        pick(u, "input_tokens", "inputTokens"),
        pick(u, "output_tokens", "outputTokens"),
        pick(u, "cache_creation_input_tokens", "cacheCreationInputTokens"),
        pick(u, "cache_read_input_tokens", "cacheReadInputTokens"),
        pick(obj, "num_turns"),
    )

def as_payload(value):
    """Return a dict/list if the value is or contains JSON, else None."""
    if isinstance(value, (dict, list)):
        return value
    if isinstance(value, str) and value.strip():
        s = value.strip()
        a, b = s.find("{"), s.rfind("}")
        if a != -1 and b > a:
            try:
                return json.loads(s[a:b + 1])
            except ValueError:
                return None
    return None

def write_result(value):
    with open(result_path, "w", encoding="utf-8") as fh:
        if isinstance(value, (dict, list)):
            json.dump(value, fh, indent=2)
        else:
            fh.write(str(value))

def emit(cost, i, o, cc, cr, turns, envelope):
    print(f"{cost}|{i}|{o}|{cc}|{cr}|{turns}|{envelope}")

try:
    text = open(raw_path, encoding="utf-8", errors="replace").read().strip()
except OSError:
    sys.exit(1)
if not text:
    sys.exit(1)

# Whole-file JSON: either a result envelope or a bare payload.
try:
    whole = json.loads(text)
except ValueError:
    whole = None

if isinstance(whole, dict) and whole.get("type") == "result":
    write_result(as_payload(whole.get("result", "")) or whole.get("result", ""))
    emit(*usage_of(whole), "true")
    sys.exit(0)

if isinstance(whole, dict):
    write_result(whole)          # bare payload, no usage available
    emit(0, 0, 0, 0, 0, 0, "false")
    sys.exit(0)

# Otherwise a JSONL stream: find the result event, keeping the last assistant
# message as a fallback payload.
result_event, last_text = None, None
for line in text.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if not isinstance(event, dict):
        continue
    if event.get("type") == "result":
        result_event = event
    elif isinstance(event.get("event"), dict) and event["event"].get("type") == "result":
        result_event = event["event"]
    if event.get("type") == "assistant":
        for block in (event.get("message") or {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text" and block.get("text"):
                last_text = block["text"]

if result_event is not None:
    payload = as_payload(result_event.get("result", "")) or as_payload(last_text or "")
    write_result(payload if payload is not None else (last_text or result_event.get("result", "")))
    emit(*usage_of(result_event), "true")
    sys.exit(0)

payload = as_payload(last_text or "")
if payload is not None or last_text:
    write_result(payload if payload is not None else last_text)
    emit(0, 0, 0, 0, 0, 0, "false")
    sys.exit(0)

sys.exit(1)
PYEOF
)

COST="0.0"; INPUT_TOKENS="0"; OUTPUT_TOKENS="0"
CACHE_CREATE="0"; CACHE_READ="0"; NUM_TURNS="0"; ENVELOPE="false"

if [ -n "$METRICS" ]; then
    IFS='|' read -r COST INPUT_TOKENS OUTPUT_TOKENS CACHE_CREATE CACHE_READ NUM_TURNS ENVELOPE <<< "$METRICS"
else
    log "WARNING: could not parse the agent output; keeping it verbatim"
    cp -f "$RAW_OUTPUT" "$LOCAL_RESULT" 2>/dev/null || true
fi

# Keep the DynamoDB numeric writes valid even if a field came back empty.
COST="${COST:-0.0}"; INPUT_TOKENS="${INPUT_TOKENS:-0}"; OUTPUT_TOKENS="${OUTPUT_TOKENS:-0}"
CACHE_CREATE="${CACHE_CREATE:-0}"; CACHE_READ="${CACHE_READ:-0}"; NUM_TURNS="${NUM_TURNS:-0}"

# Verify your usage capture before building cost reporting on it. The envelope
# reports the authoritative total for the run; the token columns below can
# under-count, because an agent's sub-agent calls may not appear in the top-level
# result. If the two disagree materially, trust the total and investigate before
# charting the columns.
if [ "$ENVELOPE" != "true" ] || [ "$COST" = "0" ] || [ "$COST" = "0.0" ]; then
    log "WARNING: usage not captured (envelope=${ENVELOPE} cost=${COST}). Raw head:"
    head -c 300 "$RAW_OUTPUT" | tr '\n' ' '; echo
fi

# Zero turns means the model was never called, so whatever is in the result is not
# agent output. The CLI reports this as exit 0 with is_error false, which is why
# this check exists: without it the item is recorded SUCCESS, the ledger row reads
# zero cost, and the batch looks complete. Fail the item instead. This is the
# cheapest possible guard against the failure mode that costs the most to find
# later, and every wrapper needs its own version of it, chosen from whatever its
# agent reports.
if [ "$ENVELOPE" = "true" ] && [ "${NUM_TURNS:-0}" = "0" ]; then
    MESSAGE="Agent made no model calls (num_turns=0); result is not agent output"
    log "ERROR: $MESSAGE"
    head -c 300 "$LOCAL_RESULT" | tr '\n' ' '; echo
    log_json "usage" "failed" "$MESSAGE"
    mark_error "$ITEM_ID" "$DURATION" "$MESSAGE"
    rm -f "$LOCAL_INPUT" "$RAW_OUTPUT" "$LOCAL_RESULT" "$STDERR_LOG"
    exit 1
fi

log "cost=${COST} tokens_in=${INPUT_TOKENS} tokens_out=${OUTPUT_TOKENS} turns=${NUM_TURNS}"
log_json "usage" "success" "cost=${COST} in=${INPUT_TOKENS} out=${OUTPUT_TOKENS} cache_create=${CACHE_CREATE} cache_read=${CACHE_READ} turns=${NUM_TURNS}"

# ============================================================
# UPLOAD THE RESULT
# ============================================================
S3_OUTPUT="s3://${S3_BUCKET}/${OUTPUT_PREFIX}/${ITEM_ID}-result.json"
if ! aws s3 cp "$LOCAL_RESULT" "$S3_OUTPUT" --region "$AWS_REGION"; then
    MESSAGE="Failed to upload result to ${S3_OUTPUT}"
    log "ERROR: $MESSAGE"
    log_json "upload" "failed" "$MESSAGE"
    mark_error "$ITEM_ID" "$DURATION" "$MESSAGE"
    rm -f "$LOCAL_INPUT" "$RAW_OUTPUT" "$LOCAL_RESULT" "$STDERR_LOG"
    exit 1
fi
log_json "upload" "success" "Uploaded to ${S3_OUTPUT}"

# ============================================================
# RECORD SUCCESS
# ============================================================
aws dynamodb update-item \
    --table-name "$DYNAMODB_TABLE" \
    --key "{\"item_id\":{\"S\":\"${ITEM_ID}\"}}" \
    --update-expression "SET processing_status = :status, end_timestamp = :end_ts, duration_seconds = :duration, cost_usd = :cost, input_tokens = :in_tok, output_tokens = :out_tok, cache_creation_tokens = :cc_tok, cache_read_tokens = :cr_tok, num_turns = :turns, output_location = :location" \
    --expression-attribute-values "{
        \":status\":{\"S\":\"SUCCESS\"},
        \":end_ts\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},
        \":duration\":{\"N\":\"${DURATION}\"},
        \":cost\":{\"N\":\"${COST}\"},
        \":in_tok\":{\"N\":\"${INPUT_TOKENS}\"},
        \":out_tok\":{\"N\":\"${OUTPUT_TOKENS}\"},
        \":cc_tok\":{\"N\":\"${CACHE_CREATE}\"},
        \":cr_tok\":{\"N\":\"${CACHE_READ}\"},
        \":turns\":{\"N\":\"${NUM_TURNS}\"},
        \":location\":{\"S\":\"${S3_OUTPUT}\"}
    }" \
    --region "$AWS_REGION"

log "SUCCESS item=${ITEM_ID} duration=${DURATION}s cost=${COST}"
log_json "complete" "success" "Item processed"

# The task is ephemeral, but remove the local copies anyway: it keeps the working
# directory clean for anyone who runs the image interactively while debugging.
rm -f "$LOCAL_INPUT" "$RAW_OUTPUT" "$LOCAL_RESULT" "$STDERR_LOG"
exit 0
