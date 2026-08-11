#!/usr/bin/env bash
# Poll configured Woodpecker repositories for pipeline-creation errors.
#
# Usage: fm-woodpecker-errors-poll.sh
#
# The public entrypoint launches itself through the fleet-ci/prd Doppler config
# with only WOODPECKER_ADMIN_TOKEN injected. The internal --from-doppler mode is
# used only by that child process and tests.
#
# Output is the authenticated custom-check contract consumed by fm-watch.sh:
#   woodpecker-error <owner>/<name> pipeline=<number> <first error message>
#   woodpecker-poll-error <deduplicated diagnostic>
# A quiet, non-error, or already-seen result prints nothing. Every remote call
# is GET-only and bounded to at most five seconds inside FM_CHECK_TIMEOUT.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REPOS_FILE="$CONFIG/woodpecker-error-repos"
SEEN_DIR="$STATE/woodpecker-errors.seen"
ERROR_DIR="$STATE/woodpecker-errors.diagnostics"
ERROR_FILE="$ERROR_DIR/error"
RECEIPT_DIR="$STATE/woodpecker-errors.receipts"
API_BASE=https://ci.appheat.co/api

# Reuse the watcher's private-artifact owner for diagnostic and seen markers.
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"

emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$ERROR_DIR" error 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$ERROR_DIR" error 600 2>/dev/null || true
  printf 'woodpecker-poll-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_file_valid "$ERROR_DIR" error 600 || return 0
  rm -f -- "$ERROR_FILE" 2>/dev/null || true
}

run_through_doppler() {
  local out rc
  command -v doppler >/dev/null 2>&1 \
    || { emit_error_once "missing doppler"; return 0; }
  out=$(doppler run -p fleet-ci -c prd \
    --only-secrets WOODPECKER_ADMIN_TOKEN \
    -- "$SCRIPT_DIR/fm-woodpecker-errors-poll.sh" --from-doppler 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    emit_error_once "Doppler access unavailable for fleet-ci/prd"
    return 0
  fi
  case "$out" in
    '') return 0 ;;
    *)
      while IFS= read -r line; do
        case "$line" in
          woodpecker-error\ *|woodpecker-poll-error\ *) printf '%s\n' "$line" ;;
          *) emit_error_once "poll returned invalid output"; return 0 ;;
        esac
      done <<< "$out"
      ;;
  esac
}

woodpecker_get() {
  local url=$1 raw elapsed remaining curl_timeout
  elapsed=$((SECONDS - POLL_STARTED_AT))
  remaining=$((POLL_BUDGET - elapsed - 1))
  if [ "$remaining" -le 0 ]; then
    emit_error_once "Woodpecker API poll timed out"
    return 1
  fi
  curl_timeout=$remaining
  [ "$curl_timeout" -gt 5 ] && curl_timeout=5
  raw=$(printf 'header = "Authorization: Bearer %s"\n' "$WOODPECKER_ADMIN_TOKEN" \
    | curl --config - --request GET --url "$url" \
      --header 'Accept: application/json' --connect-timeout 3 \
      --max-time "$curl_timeout" --silent --show-error \
      --write-out '\n%{http_code}' 2>/dev/null) \
    || { emit_error_once "Woodpecker API unreachable"; return 1; }
  case "$raw" in
    *$'\n'*) ;;
    *) emit_error_once "Woodpecker API returned no status"; return 1 ;;
  esac
  API_CODE=${raw##*$'\n'}
  API_BODY=${raw%$'\n'*}
  if [ "$API_CODE" != 200 ]; then
    emit_error_once "Woodpecker API returned HTTP $API_CODE"
    return 1
  fi
  return 0
}

mark_seen_once() {
  local identity=$1 rc
  if fmx_private_artifact_file_valid "$SEEN_DIR" "$identity" 600; then
    return 1
  fi
  printf 'seen\n' \
    | fmx_private_artifact_publish_stdin_once "$SEEN_DIR" "$identity" 600 >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) emit_error_once "could not record Woodpecker pipeline dedupe state"; return 2 ;;
  esac
}

publish_receipt_once() {
  local identity=$1 payload=$2 receipt="$RECEIPT_DIR/$identity" rc
  if fmx_private_artifact_file_valid "$RECEIPT_DIR" "$identity" 600; then
    return 1
  fi
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    return 2
  fi
  printf 'fm-woodpecker-error-receipt-v1\n%s\n%s\n' "$identity" "$payload" \
    | fmx_private_artifact_publish_stdin_once "$RECEIPT_DIR" "$identity" 600 >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) emit_error_once "could not record Woodpecker wake receipt"; return 2 ;;
  esac
}

poll_with_injected_token() {
  local token=${WOODPECKER_ADMIN_TOKEN:-} repo owner name repo_id rows
  local number message identity wake_line receipt_rc mark_rc had_error=0 saw_repo=0

  while [[ "$token" == *$'\n' || "$token" == *$'\r' ]]; do
    token=${token%?}
  done
  [ -n "$token" ] || { emit_error_once "missing WOODPECKER_ADMIN_TOKEN"; return 0; }
  case "$token" in
    *$'\n'*|*$'\r'*|*'"'*|*\\*)
      emit_error_once "invalid WOODPECKER_ADMIN_TOKEN"
      return 0
      ;;
  esac
  command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; return 0; }
  command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; return 0; }
  if [ ! -f "$REPOS_FILE" ] || [ -L "$REPOS_FILE" ]; then
    emit_error_once "config/woodpecker-error-repos must be an ordinary file"
    return 0
  fi

  POLL_BUDGET=${FM_CHECK_TIMEOUT:-30}
  case "$POLL_BUDGET" in
    ''|*[!0-9]*) POLL_BUDGET=30 ;;
  esac
  [ "$POLL_BUDGET" -gt 1 ] || POLL_BUDGET=30
  POLL_STARTED_AT=$SECONDS
  API_CODE=
  API_BODY=
  WOODPECKER_ADMIN_TOKEN=$token

  while IFS= read -r repo || [ -n "$repo" ]; do
    [ -n "$repo" ] || continue
    saw_repo=1
    case "$repo" in
      */*) ;;
      *) emit_error_once "invalid repository '$repo' in config/woodpecker-error-repos"; had_error=1; continue ;;
    esac
    owner=${repo%%/*}
    name=${repo#*/}
    case "$owner/$name" in
      */|/*|*/*/*|*[!A-Za-z0-9._/-]*)
        emit_error_once "invalid repository '$repo' in config/woodpecker-error-repos"
        had_error=1
        continue
        ;;
    esac
    case "$owner:$name" in
      .:*|..:*|*:.|*:..)
        emit_error_once "invalid repository '$repo' in config/woodpecker-error-repos"
        had_error=1
        continue
        ;;
    esac

    if ! woodpecker_get "$API_BASE/repos/lookup/$owner/$name"; then
      had_error=1
      continue
    fi
    repo_id=$(printf '%s' "$API_BODY" | jq -er '
      if (.id | type) == "number" and (.id | floor) == .id and .id >= 0
      then (.id | tostring)
      else error("invalid repository id")
      end
    ' 2>/dev/null) || {
      emit_error_once "invalid Woodpecker repository lookup response for $repo"
      had_error=1
      continue
    }

    if ! woodpecker_get "$API_BASE/repos/$repo_id/pipelines?perPage=10"; then
      had_error=1
      continue
    fi
    rows=$(printf '%s' "$API_BODY" | jq -r '
      if type != "array" then error("pipelines must be an array") else .[] end
      | select(.status == "error")
      | if ((.number | type) != "number" or (.number | floor) != .number or .number < 0)
        then error("invalid pipeline number") else . end
      | [
          (.number | tostring),
          ((if ((.errors? | type) == "array" and (.errors | length) > 0)
            then (.errors[0] | if type == "object" then (.message // tostring) else tostring end)
            elif .error? != null then (.error | tostring)
            else "unknown error"
            end) | gsub("[[:space:][:cntrl:]]+"; " ") | .[0:240])
        ]
      | @tsv
    ' 2>/dev/null) || {
      emit_error_once "invalid Woodpecker pipelines response for $repo"
      had_error=1
      continue
    }

    while IFS=$'\t' read -r number message; do
      [ -n "$number" ] || continue
      identity="repo-$repo_id-pipeline-$number"
      wake_line="woodpecker-error $repo pipeline=$number $message"
      publish_receipt_once "$identity" "$wake_line"
      receipt_rc=$?
      case "$receipt_rc" in
        0)
          mark_seen_once "$identity"
          mark_rc=$?
          case "$mark_rc" in
            0) printf '%s\n' "$wake_line" ;;
            1) ;;
            *) had_error=1 ;;
          esac
          ;;
        1) ;;
        *) had_error=1 ;;
      esac
    done <<< "$rows"
  done < "$REPOS_FILE"

  if [ "$saw_repo" -eq 0 ]; then
    emit_error_once "config/woodpecker-error-repos has no repositories"
    had_error=1
  fi
  [ "$had_error" -ne 0 ] || clear_error
}

case "${1:-}" in
  '') run_through_doppler ;;
  --from-doppler)
    [ "$#" -eq 1 ] || { emit_error_once "invalid poll invocation"; exit 0; }
    poll_with_injected_token
    ;;
  *) emit_error_once "invalid poll invocation" ;;
esac
