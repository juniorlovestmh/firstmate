#!/usr/bin/env bash
# Poll Better Stack for unresolved incidents through the fleet-observability/prd
# Doppler config.
#
# Usage: fm-better-stack-incidents-poll.sh
#
# The public entrypoint always launches itself through Doppler with fallback
# files disabled and only BETTER_STACK_API_TOKEN injected.
# The internal --from-doppler mode is used only by that child process and tests.
#
# Output is the authenticated custom-check contract consumed by fm-watch.sh:
#   better-stack-incident opened id=<id> name=<name> started=<timestamp>
#   better-stack-incidents opened ids=<comma-separated ids>
#   better-stack-error <deduplicated diagnostic>
# A quiet or already-seen result prints nothing.
# The watcher provides the outer FM_CHECK_TIMEOUT; curl stays within five
# seconds so the check finishes with margin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ERROR_DIR="$STATE/better-stack-incidents.diagnostics"
ERROR_FILE="$ERROR_DIR/error"

# Reuse the watcher's existing private-artifact owner rather than introducing a
# second atomic-publication contract for one extension.
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
  printf 'better-stack-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_file_valid "$ERROR_DIR" error 600 || return 0
  rm -f -- "$ERROR_FILE" 2>/dev/null || true
}

run_through_doppler() {
  local out rc
  command -v doppler >/dev/null 2>&1 \
    || { emit_error_once "missing doppler"; return 0; }
  out=$(doppler run \
    --silent \
    --no-check-version \
    --no-fallback \
    --project fleet-observability \
    --config prd \
    --only-secrets BETTER_STACK_API_TOKEN \
    -- "$SCRIPT_DIR/fm-better-stack-incidents-poll.sh" --from-doppler 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    emit_error_once "Doppler access unavailable for fleet-observability/prd"
    return 0
  fi
  case "$out" in
    '') return 0 ;;
    *)
      while IFS= read -r line; do
        case "$line" in
          better-stack-incident\ opened\ *|better-stack-error\ *) printf '%s\n' "$line" ;;
          *) emit_error_once "poll returned invalid output"; return 0 ;;
        esac
      done <<< "$out"
      ;;
  esac
}

poll_with_injected_token() {
  local token=${BETTER_STACK_API_TOKEN:-} raw code body page_rows page_next
  local id name started next_url='https://uptime.betterstack.com/api/v3/incidents?resolved=false&per_page=50'
  local budget=${FM_CHECK_TIMEOUT:-30} started_at=$SECONDS elapsed remaining curl_timeout

  [ -n "$token" ] || { emit_error_once "missing BETTER_STACK_API_TOKEN"; return 0; }
  [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
    || { emit_error_once "invalid BETTER_STACK_API_TOKEN"; return 0; }
  command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; return 0; }
  command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; return 0; }

  rows=
  while [ -n "$next_url" ]; do
    elapsed=$((SECONDS - started_at))
    remaining=$((budget - elapsed - 1))
    [ "$remaining" -gt 0 ] || { emit_error_once "Better Stack API poll timed out"; return 0; }
    curl_timeout=$remaining
    [ "$curl_timeout" -gt 5 ] && curl_timeout=5
    raw=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
      | curl --config - --request GET --url "$next_url" \
        --header 'Accept: application/json' --connect-timeout 3 \
        --max-time "$curl_timeout" --silent --show-error \
        --write-out '\n%{http_code}' 2>/dev/null) \
      || { emit_error_once "Better Stack API unreachable"; return 0; }
    case "$raw" in
      *$'\n'*) ;;
      *) emit_error_once "Better Stack API returned no status"; return 0 ;;
    esac
    code=${raw##*$'\n'}
    body=${raw%$'\n'*}
    [ "$code" = 200 ] || { emit_error_once "API returned HTTP $code"; return 0; }
    page_rows=$(printf '%s' "$body" | jq -r '
      if (.data | type) != "array" then error("data must be an array") else .data[] end
      | select(.type == "incident")
      | select(.attributes.resolved_at == null)
      | select(.id | type == "string" and test("^[0-9]+$"))
      | [
          .id,
          ((.attributes.name // "unknown") | tostring | gsub("[[:space:][:cntrl:]]+"; " ") | .[0:120]),
          ((.attributes.started_at // "unknown") | tostring | gsub("[[:space:][:cntrl:]]+"; " ") | .[0:64])
        ]
      | @tsv
    ' 2>/dev/null) || { emit_error_once "invalid Better Stack API response"; return 0; }
    [ -z "$rows" ] || [ -z "$page_rows" ] || rows="$rows"$'\n'
    rows="$rows$page_rows"
    page_next=$(printf '%s' "$body" | jq -r '
      if ((.pagination.next // null) != null and (.pagination.next | type) != "string")
      then error("pagination.next must be a string")
      else (.pagination.next // "") end
    ' 2>/dev/null) || { emit_error_once "invalid Better Stack API response"; return 0; }
    case "$page_next" in
      '') next_url= ;;
      https://uptime.betterstack.com/api/v3/incidents\?*)
        case "$page_next" in *resolved=false*) next_url=$page_next ;; *) emit_error_once "invalid Better Stack pagination target"; return 0 ;; esac
        ;;
      *) emit_error_once "invalid Better Stack pagination target"; return 0 ;;
    esac
  done

  while IFS=$'\t' read -r id name started; do
    [ -n "$id" ] || continue
    printf 'better-stack-incident opened id=%s name=%s started=%s\n' "$id" "$name" "$started"
  done <<< "$rows"

  clear_error
}

case "${1:-}" in
  '') run_through_doppler ;;
  --from-doppler)
    [ "$#" -eq 1 ] || { emit_error_once "invalid poll invocation"; exit 0; }
    poll_with_injected_token
    ;;
  *) emit_error_once "invalid poll invocation" ;;
esac
