#!/usr/bin/env bash
# fm-analytics-export.sh - Slice 1 local-first crew analytics exporter.
#
# Rebuildable, deterministic export of redacted operational counts from durable
# Firstmate home records only. No network, no LLM calls, no mutation of inputs.
#
# Inputs (read-only):
#   $FM_HOME/data/backlog.md
#   $FM_HOME/data/done-archive.md   (optional)
#   $FM_HOME/state/*.status
#   $FM_HOME/data/learnings.md      (headers only; body text is never exported)
#
# Outputs (idempotent per calendar day UTC, overwritten on re-run):
#   $FM_HOME/data/analytics/SCHEMA_VERSION
#   $FM_HOME/data/analytics/snapshots/YYYY-MM-DD.json
#   $FM_HOME/data/analytics/snapshots/YYYY-MM-DD.tsv
#   $FM_HOME/data/analytics/LAST_EXPORT
#
# Schema: fm-analytics.v1 (see data/firstmate-crew-analytics-s18 design; Slice 1
# here is the durable-records subset approved for this ship — no live meta, no
# no-mistakes axi, no gh, no disk/Herdr capacity probes).
#
# Metrics:
#   Per task from status logs: verb histogram, needs-decision/resolved pair
#   counts, respawns (working: after any prior non-working verb — re-entry proxy),
#   done_with_pr vs failed terminal flags.
#   Backlog section counts from markdown checkbox rows.
#   Repeat-incident section: learnings H2 headers keyed by class slug; classes
#   with count >= 2 are marked repeated.
#
# Usage:
#   fm-analytics-export.sh
#   FM_HOME=/path/to/home fm-analytics-export.sh
#   FM_ANALYTICS_DATE=2026-07-22 fm-analytics-export.sh   # pin day (tests)
#   FM_ANALYTICS_NOW=2026-07-22T15:00:00Z fm-analytics-export.sh
#
# Exit: 0 on success, 1 on usage/tooling error, 2 on bad environment.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ANALYTICS_DIR="${FM_ANALYTICS_DIR_OVERRIDE:-$DATA/analytics}"

command -v jq >/dev/null 2>&1 || {
  echo "fm-analytics-export: jq not found" >&2
  exit 1
}

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage: fm-analytics-export.sh

Write one rebuildable redacted analytics snapshot for the current UTC day under
$FM_HOME/data/analytics/snapshots/. Read-only on inputs; idempotent per day.

Environment:
  FM_HOME                 operational home (default: firstmate root)
  FM_STATE_OVERRIDE       override state dir
  FM_DATA_OVERRIDE        override data dir
  FM_ANALYTICS_DIR_OVERRIDE  override analytics output root
  FM_ANALYTICS_DATE       YYYY-MM-DD snapshot day (default: UTC today)
  FM_ANALYTICS_NOW        ISO8601 UTC exported_at (default: now)
EOF
  exit 2
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ $# -eq 0 ] || usage

if [ -n "${FM_ANALYTICS_NOW:-}" ]; then
  EXPORTED_AT=$FM_ANALYTICS_NOW
else
  EXPORTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

if [ -n "${FM_ANALYTICS_DATE:-}" ]; then
  SNAP_DAY=$FM_ANALYTICS_DATE
else
  SNAP_DAY=${EXPORTED_AT%%T*}
fi
case "$SNAP_DAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *)
    echo "fm-analytics-export: FM_ANALYTICS_DATE must be YYYY-MM-DD (got '$SNAP_DAY')" >&2
    exit 2
    ;;
esac

# Privacy-stable home label: last two path components only (no full absolute path).
home_label() {
  local p=$1 a b
  p=${p%/}
  b=${p##*/}
  a=${p%/*}
  a=${a##*/}
  if [ -n "$a" ] && [ "$a" != "$p" ]; then
    printf '%s/%s' "$a" "$b"
  else
    printf '%s' "$b"
  fi
}
FM_HOME_LABEL=$(home_label "$FM_HOME")

mkdir -p "$ANALYTICS_DIR/snapshots"
printf '%s\n' 'fm-analytics.v1' >"$ANALYTICS_DIR/SCHEMA_VERSION"

BACKLOG="$DATA/backlog.md"
ARCHIVE="$DATA/done-archive.md"
LEARNINGS="$DATA/learnings.md"

# --- backlog section counts (checkbox task rows only; no free-form notes) ----
# Matches: - [ ] id - title ...  and  - [x] id - title ...
count_section_tasks() {  # <file> <section-heading-regex> -> integer
  local file=$1 section=$2
  [ -f "$file" ] || {
    printf '0'
    return
  }
  awk -v sec="$section" '
    BEGIN { insec=0; n=0 }
    /^## / {
      if ($0 ~ sec) { insec=1; next }
      if (insec) exit
    }
    insec && match($0, /^- \[[ xX]\] [A-Za-z0-9][A-Za-z0-9._-]* /) { n++ }
    END { print n+0 }
  ' "$file"
}

BACKLOG_IN_FLIGHT=$(count_section_tasks "$BACKLOG" '^## In flight')
BACKLOG_QUEUED=$(count_section_tasks "$BACKLOG" '^## Queued')
BACKLOG_DONE=$(count_section_tasks "$BACKLOG" '^## Done')
if [ -f "$ARCHIVE" ]; then
  ARCHIVE_DONE=$(awk 'match($0, /^- \[[xX]\] [A-Za-z0-9][A-Za-z0-9._-]* /) { n++ } END { print n+0 }' "$ARCHIVE")
else
  ARCHIVE_DONE=0
fi

# Collect task ids from backlog + archive + residual status files.
collect_ids() {
  local f base
  for f in "$BACKLOG" "$ARCHIVE"; do
    [ -f "$f" ] || continue
    # Checkbox task rows: "- [ ] id - title" / "- [x] id - title"
    # Capture id with a regex so the space inside "[ ]" is not field-split.
    sed -nE 's/^- \[[ xX]\] ([A-Za-z0-9][A-Za-z0-9._-]*)( |$).*/\1/p' "$f"
  done
  if [ -d "$STATE" ]; then
    for f in "$STATE"/*.status; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      printf '%s\n' "${base%.status}"
    done
  fi
}

# --- per-task status metrics (verbs only; notes never leave this process) ----
# Prints one TSV row:
# id \t events \t working \t needs_decision \t resolved \t blocked \t paused
#    \t failed \t done \t respawns \t done_with_pr \t failed_terminal \t decision_pairs \t last_verb
analyze_status() {  # <status-file> <task-id>
  local file=$1 id=$2
  local line verb note key prev='' open_decisions=''
  local events=0 working=0 needs_decision=0 resolved=0 blocked=0 paused=0
  local failed=0 done=0 respawns=0 done_with_pr=0 failed_terminal=0 decision_pairs=0 last_verb=''

  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      # Skip pure whitespace
      case "$line" in
        *[![:space:]]*) ;;
        *) continue ;;
      esac
      verb=$(status_line_verb "$line")
      [ -n "$verb" ] || continue
      events=$((events + 1))
      last_verb=$verb
      case "$verb" in
        working)
          working=$((working + 1))
          # Respawn proxy: re-entering working after any other verb (not the
          # first working: of the stream, and not consecutive working lines).
          if [ -n "$prev" ] && [ "$prev" != working ]; then
            respawns=$((respawns + 1))
          fi
          ;;
        needs-decision|blocked)
          [ "$verb" = needs-decision ] && needs_decision=$((needs_decision + 1))
          [ "$verb" = blocked ] && blocked=$((blocked + 1))
          key=$(_fm_decision_key "$line") || key=''
          if [ -n "$key" ]; then
            open_decisions=$(_fm_decision_drop "$open_decisions" "$key")
            [ -n "$open_decisions" ] && open_decisions="${open_decisions}"$'\n'
            open_decisions="${open_decisions}${key}"$'\t'"${verb}"$'\t'"$(status_line_note "$line")"$'\n'
          fi
          failed_terminal=0
          ;;
        resolved)
          resolved=$((resolved + 1))
          key=$(_fm_decision_key "$line") || key=''
          if [ -n "$key" ] && [[ "$open_decisions" == *"${key}"$'\t'* ]]; then
            decision_pairs=$((decision_pairs + 1))
            open_decisions=$(_fm_decision_drop "$open_decisions" "$key")
          fi
          failed_terminal=0
          ;;
        paused) paused=$((paused + 1)) ;;
        failed)
          failed=$((failed + 1))
          failed_terminal=1
          done_with_pr=0
          ;;
        done)
          done=$((done + 1))
          failed_terminal=0
          note=$(status_line_note "$line")
          case "$note" in
            *'PR '*|*'checks green'*|*/pull/*)
              done_with_pr=1
              ;;
          esac
          ;;
      esac
      [ "$verb" = failed ] || failed_terminal=0
      prev=$verb
    done <"$file"
  fi

  printf '%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n' \
    "$id" "$events" "$working" "$needs_decision" "$resolved" "$blocked" \
    "$paused" "$failed" "$done" "$respawns" "$done_with_pr" "$failed_terminal" "$decision_pairs" \
    "$last_verb"
}

TASK_TSV=$(mktemp "${TMPDIR:-/tmp}/fm-analytics-tasks.XXXXXX")
LEARN_TSV=$(mktemp "${TMPDIR:-/tmp}/fm-analytics-learn.XXXXXX")
TASK_JSON=$(mktemp "${TMPDIR:-/tmp}/fm-analytics-tasks-json.XXXXXX")
LEARN_JSON=$(mktemp "${TMPDIR:-/tmp}/fm-analytics-learn-json.XXXXXX")
SUMMARY_JSON=$(mktemp "${TMPDIR:-/tmp}/fm-analytics-summary.XXXXXX")
trap 'rm -f "$TASK_TSV" "$LEARN_TSV" "$TASK_JSON" "$LEARN_JSON" "$SUMMARY_JSON"' EXIT

{
  collect_ids | sort -u | while IFS= read -r id; do
    [ -n "$id" ] || continue
    analyze_status "$STATE/$id.status" "$id"
  done
} >"$TASK_TSV"

# --- learnings headers -> class counts (title text only, not body) -----------
# Headers look like: ## 2026-08-03 - Title here
#                 or ## 2026-08-03 — Title here
: >"$LEARN_TSV"
if [ -f "$LEARNINGS" ]; then
  awk '
    /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
      line=$0
      sub(/^## /, "", line)
      # drop date prefix
      sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*[-—–][[:space:]]*/, "", line)
      # normalize class slug: lowercase, non-alnum -> single dash
      title=line
      out=""
      for (i=1; i<=length(title); i++) {
        c=substr(title, i, 1)
        if (c ~ /[A-Z]/) c=tolower(c)
        if (c ~ /[a-z0-9]/) out=out c
        else if (out != "" && substr(out, length(out), 1) != "-") out=out "-"
      }
      while (out ~ /-$/) out=substr(out, 1, length(out)-1)
      while (out ~ /--/) gsub(/--/, "-", out)
      if (out == "") out="untitled"
      # keep a short class key (first 80 chars of slug)
      if (length(out) > 80) out=substr(out, 1, 80)
      print out
    }
  ' "$LEARNINGS" | sort | uniq -c | sort -k1,1nr -k2,2 | while read -r cnt class; do
    [ -n "$class" ] || continue
    repeated=0
    [ "$cnt" -ge 2 ] && repeated=1
    printf '%s\t%d\t%d\n' "$class" "$cnt" "$repeated"
  done >"$LEARN_TSV"
fi

# --- assemble JSON via jq ----------------------------------------------------

if [ -s "$TASK_TSV" ]; then
  jq -R -s -c '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map(select(length >= 14))
    | map({
        id: .[0],
        events: (.[1]|tonumber),
        verbs: {
          working: (.[2]|tonumber),
          "needs-decision": (.[3]|tonumber),
          resolved: (.[4]|tonumber),
          blocked: (.[5]|tonumber),
          paused: (.[6]|tonumber),
          failed: (.[7]|tonumber),
          done: (.[8]|tonumber)
        },
        respawns: (.[9]|tonumber),
        done_with_pr: ((.[10]|tonumber) == 1),
        failed_terminal: ((.[11]|tonumber) == 1),
        decision_pairs: (.[12]|tonumber),
        last_verb: (if .[13] == "" then null else .[13] end)
      })
  ' <"$TASK_TSV" >"$TASK_JSON"
else
  printf '[]\n' >"$TASK_JSON"
fi

if [ -s "$LEARN_TSV" ]; then
  jq -R -s -c '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map(select(length >= 3))
    | map({
        class: .[0],
        count: (.[1]|tonumber),
        repeated: ((.[2]|tonumber) == 1)
      })
  ' <"$LEARN_TSV" >"$LEARN_JSON"
else
  printf '[]\n' >"$LEARN_JSON"
fi

# Rollup summary from task rows
jq -c '
  {
    tasks_with_status: length,
    total_status_events: (map(.events) | add // 0),
    total_needs_decision: (map(.verbs["needs-decision"]) | add // 0),
    total_resolved: (map(.verbs.resolved) | add // 0),
    total_decision_pairs: (map(.decision_pairs) | add // 0),
    total_respawns: (map(.respawns) | add // 0),
    done_with_pr: (map(select(.done_with_pr)) | length),
    failed_terminal: (map(select(.failed_terminal)) | length),
    verb_totals: {
      working: (map(.verbs.working) | add // 0),
      "needs-decision": (map(.verbs["needs-decision"]) | add // 0),
      resolved: (map(.verbs.resolved) | add // 0),
      blocked: (map(.verbs.blocked) | add // 0),
      paused: (map(.verbs.paused) | add // 0),
      failed: (map(.verbs.failed) | add // 0),
      done: (map(.verbs.done) | add // 0)
    }
  }
' <"$TASK_JSON" >"$SUMMARY_JSON"

REPEAT_CLASSES=$(jq -c '[.[] | select(.repeated) | .class]' <"$LEARN_JSON")
REPEAT_COUNT=$(jq -c '[.[] | select(.repeated)] | length' <"$LEARN_JSON")
LEARN_ENTRY_TOTAL=$(jq -c 'map(.count) | add // 0' <"$LEARN_JSON")

SNAP_JSON="$ANALYTICS_DIR/snapshots/${SNAP_DAY}.json"
SNAP_TSV="$ANALYTICS_DIR/snapshots/${SNAP_DAY}.tsv"

jq -n \
  --arg schema "fm-analytics.v1" \
  --arg exported_at "$EXPORTED_AT" \
  --arg day "$SNAP_DAY" \
  --arg fm_home_label "$FM_HOME_LABEL" \
  --argjson backlog_in_flight "$BACKLOG_IN_FLIGHT" \
  --argjson backlog_queued "$BACKLOG_QUEUED" \
  --argjson backlog_done "$BACKLOG_DONE" \
  --argjson archive_done "$ARCHIVE_DONE" \
  --slurpfile tasks "$TASK_JSON" \
  --slurpfile summary "$SUMMARY_JSON" \
  --slurpfile learnings "$LEARN_JSON" \
  --argjson repeat_classes "$REPEAT_CLASSES" \
  --argjson repeat_class_count "$REPEAT_COUNT" \
  --argjson learnings_entries "$LEARN_ENTRY_TOTAL" \
  '{
    schema: $schema,
    exported_at: $exported_at,
    day: $day,
    fm_home_label: $fm_home_label,
    inputs: {
      backlog: true,
      done_archive: true,
      status_logs: true,
      learnings_headers: true
    },
    backlog: {
      in_flight: $backlog_in_flight,
      queued: $backlog_queued,
      done_kept: $backlog_done,
      done_archived: $archive_done
    },
    summary: $summary[0],
    tasks: ($tasks[0] | sort_by(.id)),
    repeat_incidents: {
      learnings_entries: $learnings_entries,
      classes: $learnings[0],
      repeated_class_count: $repeat_class_count,
      repeated_classes: $repeat_classes
    },
    notes: {
      slice: "1-durable-records",
      design_delta: "Approved s18 Slice 1 mentioned fleet-snapshot/meta/df/NM overlays; this ship exports only durable backlog/status/learnings counts per the execution brief. ISO status timestamps ship alongside and unlock duration metrics later."
    }
  }' >"$SNAP_JSON"

# TSV: header + per-task rows (stable column order)
{
  printf 'id\tevents\tworking\tneeds_decision\tresolved\tblocked\tpaused\tfailed\tdone\trespawns\tdone_with_pr\tfailed_terminal\tdecision_pairs\tlast_verb\n'
  if [ -s "$TASK_TSV" ]; then
    while IFS=$'\t' read -r id events working nd res blocked paused failed done_n respawns dpr fterm pairs last; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$events" "$working" "$nd" "$res" "$blocked" "$paused" \
        "$failed" "$done_n" "$respawns" "$dpr" "$fterm" "$pairs" "$last"
    done <"$TASK_TSV"
  fi
} >"$SNAP_TSV"

printf '%s\t%s\n' "$EXPORTED_AT" "snapshots/${SNAP_DAY}.json" >"$ANALYTICS_DIR/LAST_EXPORT"

printf 'fm-analytics-export: wrote %s and %s\n' "$SNAP_JSON" "$SNAP_TSV"
