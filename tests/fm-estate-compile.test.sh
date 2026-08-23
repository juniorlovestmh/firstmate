#!/usr/bin/env bash
# Public-interface behavior tests for estate YAML compilation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMPILE="$ROOT/bin/fm-estate-compile.sh"
EXAMPLES="$ROOT/docs/examples/estate-catalog"
TMP_ROOT=$(fm_test_tmproot fm-estate-compile)

compile_at() {
  local catalog=$1 now=${2:-2026-08-10T00:00:00Z}
  FM_ESTATE_CATALOG_DIR="$catalog" FM_ESTATE_NOW="$now" "$COMPILE"
}

test_examples_compile_deterministically() {
  local catalog="$TMP_ROOT/examples" first_json="$TMP_ROOT/first.json" first_md="$TMP_ROOT/first.md"
  mkdir -p "$catalog/declared"
  cp "$EXAMPLES"/*.yaml "$catalog/declared/"

  compile_at "$catalog" >/dev/null || fail "example catalog did not compile"
  jq -e '
    .schema_version == "estate-catalog.v1" and
    (.entities | length == 10) and
    ([.entities[].kind] | unique | length == 10) and
    (all(.entities[]; has("source") and has("collected_at") and has("authority") and has("stale")))
  ' "$catalog/compiled/estate.json" >/dev/null \
    || fail "compiled JSON did not contain one normalized entity per example kind"
  assert_grep "# Estate catalog" "$catalog/compiled/estate.md" \
    "compiled Markdown heading is missing"
  assert_grep "woodpecker" "$catalog/compiled/estate.md" \
    "compiled Markdown omitted the CI example"
  cp "$catalog/compiled/estate.json" "$first_json"
  cp "$catalog/compiled/estate.md" "$first_md"

  compile_at "$catalog" >/dev/null || fail "second deterministic compile failed"
  cmp -s "$first_json" "$catalog/compiled/estate.json" \
    || fail "same inputs and evaluation time produced different JSON"
  cmp -s "$first_md" "$catalog/compiled/estate.md" \
    || fail "same inputs and evaluation time produced different Markdown"
  jq -e '."$schema" == "https://json-schema.org/draft/2020-12/schema"' \
    "$EXAMPLES/schema.json" >/dev/null || fail "catalog schema is not valid JSON Schema metadata"
  pass "estate compile parses every YAML example and emits deterministic JSON and Markdown"
}

test_compile_marks_age_and_collector_failure_stale() {
  local catalog="$TMP_ROOT/stale"
  mkdir -p "$catalog/generated"
  cat >"$catalog/generated/compute.yaml" <<'YAML'
schema_version: 1
kind: host
status:
  state: stale
  marked_at: "2026-08-09T12:00:00Z"
  reason: "collector unavailable"
entities:
  - id: "gh-runner-t1"
    provider: "proxmox"
    vmid: 120
    ip: "192.168.1.120"
    role: "runner"
    ssh_path: "ubuntu@192.168.1.120"
    source: "collected"
    collected_at: "2026-08-09T00:00:00Z"
    authority: "fm-estate-collect-proxmox.sh"
YAML

  compile_at "$catalog" >/dev/null || fail "stale collector slice did not compile"
  jq -e '
    .entities[0].stale == true and
    .entities[0].stale_reason == "collector unavailable" and
    .entities[0].stale_after_days == 7
  ' "$catalog/compiled/estate.json" >/dev/null \
    || fail "collector failure did not mark its compiled slice stale"

  sed -i.bak '/^status:/,$d' "$catalog/generated/compute.yaml"
  rm -f "$catalog/generated/compute.yaml.bak"
  cat >>"$catalog/generated/compute.yaml" <<'YAML'
entities:
  - id: "gh-runner-t1"
    provider: "proxmox"
    vmid: 120
    ip: "192.168.1.120"
    role: "runner"
    ssh_path: "ubuntu@192.168.1.120"
    source: "collected"
    collected_at: "2026-08-01T00:00:00Z"
    authority: "fm-estate-collect-proxmox.sh"
YAML
  compile_at "$catalog" >/dev/null || fail "aged compute slice did not compile"
  jq -e '.entities[0].stale == true and (.entities[0].stale_reason | contains("older than 7 days"))' \
    "$catalog/compiled/estate.json" >/dev/null \
    || fail "compute older than seven days was not marked stale"
  pass "estate compile marks explicit collector failure and over-age compute stale"
}

test_compile_rejects_duplicate_entity_truth() {
  local catalog="$TMP_ROOT/duplicate" out rc
  mkdir -p "$catalog/declared"
  cp "$EXAMPLES/system.yaml" "$catalog/declared/a.yaml"
  cp "$EXAMPLES/system.yaml" "$catalog/declared/b.yaml"
  set +e
  out=$(compile_at "$catalog" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate entity truth was silently accepted"
  assert_contains "$out" "duplicate entity system:" \
    "duplicate entity failure did not name the conflicting identity"
  assert_absent "$catalog/compiled/estate.json" \
    "failed compile published a partial JSON catalog"
  pass "estate compile fails closed on duplicate entity truth"
}

test_compile_rejects_out_of_schema_fields() {
  local catalog="$TMP_ROOT/out-of-schema" out rc
  mkdir -p "$catalog/declared"
  cp "$EXAMPLES/system.yaml" "$catalog/declared/system.yaml"
  printf '%s\n' '    github: "appheat/not-a-system-field"' >>"$catalog/declared/system.yaml"
  set +e
  out=$(compile_at "$catalog" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "kind-incompatible fields were silently accepted"
  assert_contains "$out" "fields are not valid for system: github" \
    "schema refusal did not identify the incompatible field"
  pass "estate compile enforces the kind-specific schema"
}

test_examples_compile_deterministically
test_compile_marks_age_and_collector_failure_stale
test_compile_rejects_duplicate_entity_truth
test_compile_rejects_out_of_schema_fields
