#!/usr/bin/env bash
# End-to-end behavior tests for compile plus mandatory estate consultation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMPILE="$ROOT/bin/fm-estate-compile.sh"
CONSULT="$ROOT/bin/fm-estate-consult.sh"
TMP_ROOT=$(fm_test_tmproot fm-estate-consult)
NOW=2026-08-10T00:00:00Z

write_ci() {
  local catalog=$1
  mkdir -p "$catalog/declared"
  cat >"$catalog/declared/ci.yaml" <<'YAML'
schema_version: 1
kind: ci
entities:
  - id: "woodpecker"
    product: "woodpecker"
    url: "https://ci.appheat.co"
    agent_labels: ["repo=appheat/bible-agents"]
    notes: "API mutations use the VM-local endpoint."
    source: "declarative"
    collected_at: "2026-08-09T00:00:00Z"
    authority: "fleet operator"
YAML
}

write_host() {
  local catalog=$1 collected_at=$2 ip=${3:-192.168.1.112}
  mkdir -p "$catalog/declared"
  cat >"$catalog/declared/host.yaml" <<YAML
schema_version: 1
kind: host
entities:
  - id: "woodpecker-ci"
    provider: "proxmox"
    vmid: 110
    ip: "$ip"
    role: "ci"
    ssh_path: "ubuntu@192.168.1.112"
    source: "declarative"
    collected_at: "$collected_at"
    authority: "fleet operator"
YAML
}

compile_catalog() {
  FM_ESTATE_CATALOG_DIR="$1" FM_ESTATE_NOW="$NOW" "$COMPILE" >/dev/null
}

consult_ci() {
  FM_ESTATE_CATALOG_DIR="$1" FM_ESTATE_NOW="$NOW" "$CONSULT" ci
}

test_current_round_trip_prints_brief_block() {
  local catalog="$TMP_ROOT/current" out
  write_ci "$catalog"
  write_host "$catalog" "2026-08-09T00:00:00Z"
  compile_catalog "$catalog" || fail "current fixture did not compile"
  out=$(consult_ci "$catalog") || fail "current CI consultation failed: $out"
  assert_contains "$out" "Estate already exists" "brief injection heading is missing"
  assert_contains "$out" "[ci] woodpecker" "existing Woodpecker CI was not printed"
  assert_contains "$out" "[host] woodpecker-ci" "existing Woodpecker host was not printed"
  assert_contains "$out" "Unknown surfaces" "unknown-surface heading is missing"
  assert_contains "$out" "- none" "current complete estate should have no unknown surfaces"
  pass "estate consult prints a paste-ready current CI estate block"
}

test_missing_required_kind_refuses() {
  local catalog="$TMP_ROOT/missing" out rc
  write_ci "$catalog"
  compile_catalog "$catalog" || fail "missing-kind fixture did not compile"
  set +e
  out=$(consult_ci "$catalog" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing host refusal"
  assert_contains "$out" "missing required kind: host" \
    "missing-kind refusal did not identify host inventory"
  pass "estate consult refuses CI work when its host estate kind is missing"
}

test_stale_required_kind_refuses() {
  local catalog="$TMP_ROOT/stale" out rc
  write_ci "$catalog"
  write_host "$catalog" "2026-08-01T00:00:00Z"
  compile_catalog "$catalog" || fail "stale fixture did not compile"
  set +e
  out=$(consult_ci "$catalog" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "stale host refusal"
  assert_contains "$out" "stale required entity: host:woodpecker-ci" \
    "stale refusal did not identify the over-age host"
  pass "estate consult refuses CI work when compute truth is older than seven days"
}

test_unknown_required_field_refuses() {
  local catalog="$TMP_ROOT/unknown" out rc
  write_ci "$catalog"
  write_host "$catalog" "2026-08-09T00:00:00Z" unknown
  compile_catalog "$catalog" || fail "unknown-field fixture did not compile"
  set +e
  out=$(consult_ci "$catalog" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unknown host field refusal"
  assert_contains "$out" "unknown required fields: host:woodpecker-ci (ip)" \
    "unknown-surface refusal did not identify the incomplete host"
  pass "estate consult refuses incomplete required infrastructure truth"
}

test_current_round_trip_prints_brief_block
test_missing_required_kind_refuses
test_stale_required_kind_refuses
test_unknown_required_field_refuses
