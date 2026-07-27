#!/usr/bin/env bash
# Contract tests for Firstmate's shared Doppler policy, rollout manifest, and
# value-safe deterministic checker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-secrets-check.sh"
SKILL="$ROOT/.agents/skills/secrets-management/SKILL.md"
SCHEMA="$ROOT/docs/secrets-policy.schema.json"
ROLLOUT_SCHEMA="$ROOT/docs/secrets-rollout.schema.json"
ROLLOUT="$ROOT/docs/secrets-rollout.json"
EXAMPLE="$ROOT/docs/examples/project-secrets-policy.json"
PROJECT_MANAGEMENT="$ROOT/.agents/skills/project-management/SKILL.md"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-secrets-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

test_public_entrypoint_validates_tracked_standard() {
  local out
  assert_present "$CHECK" "public secrets-policy checker is missing"
  [ -x "$CHECK" ] || fail "public secrets-policy checker is not executable"
  out=$("$CHECK" 2>&1) || fail "tracked secrets standard did not validate"$'\n'"$out"
  assert_contains "$out" "secrets-standard: ok" "checker did not report standard validation"
  assert_contains "$out" "projects=8" "checker did not validate the exact eight-project rollout"
  assert_contains "$out" "leak-scan: ok files=17" \
    "default dogfood did not scan every tracked standard and integration artifact"
  pass "secrets checker validates the tracked standard and eight-project rollout"
}

test_policy_owner_has_one_precise_trigger() {
  local count
  assert_present "$SKILL" "secrets-management skill is missing"
  assert_grep "name: secrets-management" "$SKILL" "secrets-management skill metadata has the wrong name"
  assert_grep "user-invocable: false" "$SKILL" "secrets-management skill must not be user-invocable"
  assert_grep "single owner of Firstmate's secrets-management policy" "$SKILL" \
    "secrets-management skill does not declare policy ownership"
  count=$(grep -Fc -- "- \`secrets-management\` -" "$ROOT/AGENTS.md")
  [ "$count" -eq 1 ] || fail "secrets-management must have exactly one AGENTS.md trigger entry, found $count"
  assert_grep "load before project intake or initialization and before work that handles credentials or adds secret access to CI or deployment" "$ROOT/AGENTS.md" \
    "AGENTS.md lost the precise secrets-management trigger"
  assert_grep "run \`bin/fm-secrets-check.sh inventory projects/<name>\`" "$PROJECT_MANAGEMENT" \
    "project initialization does not run the value-safe inventory entrypoint"
  assert_grep "copy and complete \`docs/examples/project-secrets-policy.json\`" "$PROJECT_MANAGEMENT" \
    "project initialization does not schedule the project manifest contract"
  pass "secrets-management has one precise always-loaded trigger"
}

test_paid_oidc_remains_captain_owned_recommendation() {
  local out
  assert_grep "Config-scoped read-only service tokens are the shipped CI default." "$SKILL" \
    "service tokens are not declared as the shipped CI default"
  assert_grep "Whether that benefit justifies the paid plan is the captain's decision." "$SKILL" \
    "paid OIDC decision is not reserved for the captain"
  assert_grep "Team at \$21 per user per month" "$SKILL" \
    "OIDC recommendation does not record the checked Team-plan price"
  out=$(python3 - "$ROLLOUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    assessment = json.load(fh)["oidcAssessment"]

assert assessment["decisionOwner"] == "captain"
assert assessment["status"] == "recommendation-only"
assert assessment["teamPriceUsdPerUserMonth"] == 21
assert assessment["enterprisePrice"] == "custom"
assert "read-only service token" in assessment["shippedDefault"]
assert "no Team-plan" in assessment["shippedDefault"]
print("captain-owned recommendation; service-token default")
PY
)
  assert_contains "$out" "service-token default" \
    "rollout does not keep service tokens as the paid-plan-independent default"
  pass "paid OIDC stays a costed captain-owned recommendation"
}

test_schemas_and_example_are_publicly_validated() {
  local path out
  for path in "$SCHEMA" "$ROLLOUT_SCHEMA" "$ROLLOUT" "$EXAMPLE"; do
    assert_present "$path" "required secrets standard artifact is missing: $path"
  done
  out=$("$CHECK" manifest "$EXAMPLE" 2>&1) \
    || fail "example project secrets manifest did not validate"$'\n'"$out"
  assert_contains "$out" "manifest: ok" "checker did not report project manifest validation"
  pass "public schemas, rollout, and project example validate"
}

test_schema_patterns_and_unknown_fields_are_enforced() {
  local manifest out rc
  manifest="$TMP_ROOT/schema-violations.json"
  cat >"$manifest" <<'EOF'
{
  "schemaVersion": 1,
  "project": "Bad Name",
  "repository": "owner/extra/name",
  "classification": "doppler",
  "doppler": {
    "project": "example",
    "configs": ["dev"]
  },
  "ci": {
    "runner": "owned-linux",
    "identity": "doppler-service-token",
    "injection": "per-job-doppler-fetch"
  },
  "exceptions": [],
  "review": {
    "owner": "project-maintainer",
    "cadenceDays": 90
  },
  "credentialValue": "must-not-exist"
}
EOF
  rc=0
  out=$("$CHECK" manifest "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "checker accepted fields forbidden by the public schema"
  assert_contains "$out" '$.project must match' "checker did not enforce the project slug pattern"
  assert_contains "$out" '$.repository must match' "checker did not enforce owner/name"
  assert_contains "$out" '$.credentialValue is not allowed' "checker did not reject an unknown field"
  pass "manifest checker executes schema patterns and field closure"
}

test_undocumented_exception_is_rejected() {
  local manifest out rc
  manifest="$TMP_ROOT/undocumented-exception.json"
  cat >"$manifest" <<'EOF'
{
  "schemaVersion": 1,
  "project": "example",
  "repository": "example/example",
  "classification": "secretless",
  "doppler": {
    "project": null,
    "configs": []
  },
  "ci": {
    "runner": "owned-linux",
    "identity": "none",
    "injection": "none"
  },
  "exceptions": [
    {
      "kind": "secretless",
      "scope": "all",
      "reason": ""
    }
  ],
  "review": {
    "owner": "project-maintainer",
    "cadenceDays": 90
  }
}
EOF
  rc=0
  out=$("$CHECK" manifest "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "checker accepted an exception without a reason"
  assert_contains "$out" "exceptions[0].reason" "checker did not identify the undocumented exception"
  pass "project manifest rejects an exception without a reason"
}

test_temporary_migration_requires_removal_contract() {
  local manifest out rc
  manifest="$TMP_ROOT/unbounded-migration.json"
  cat >"$manifest" <<'EOF'
{
  "schemaVersion": 1,
  "project": "example",
  "repository": "example/example",
  "classification": "doppler",
  "doppler": {
    "project": "example",
    "configs": ["stg"]
  },
  "ci": {
    "runner": "owned-linux",
    "identity": "doppler-service-token",
    "injection": "per-job-doppler-fetch"
  },
  "exceptions": [
    {
      "kind": "temporary-migration",
      "scope": "legacy path",
      "reason": "A bounded transition is required."
    }
  ],
  "review": {
    "owner": "project-maintainer",
    "cadenceDays": 90
  }
}
EOF
  rc=0
  out=$("$CHECK" manifest "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "checker accepted an unbounded temporary migration"
  assert_contains "$out" "reviewBy" "checker did not require a migration review date"
  assert_contains "$out" "removalCondition" "checker did not require a removal condition"
  pass "temporary migrations require a dated removal contract"
}

test_identity_and_exception_cross_fields_are_enforced() {
  local platform_manifest injection_manifest out rc
  platform_manifest="$TMP_ROOT/platform-native-without-reason.json"
  injection_manifest="$TMP_ROOT/service-token-without-injection.json"

  sed 's/"classification": "doppler"/"classification": "platform-native"/' \
    "$EXAMPLE" >"$platform_manifest"
  rc=0
  out=$("$CHECK" manifest "$platform_manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "checker accepted platform-native without a documented exception"
  assert_contains "$out" "platform-mandated" \
    "checker did not require the platform-native authority reason"

  sed 's/"injection": "per-job-doppler-fetch"/"injection": "none"/' \
    "$EXAMPLE" >"$injection_manifest"
  rc=0
  out=$("$CHECK" manifest "$injection_manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "checker accepted a service token with no injection path"
  assert_contains "$out" "per-job-doppler-fetch" \
    "checker did not bind service-token identity to per-job injection"
  pass "identity and exception cross-field contracts are enforced"
}

test_value_leak_scan_reports_rule_not_value() {
  local clean bad canary out rc
  clean="$TMP_ROOT/clean-policy.txt"
  bad="$TMP_ROOT/bad-policy.txt"
  printf '%s\n' 'DOPPLER_TOKEN is an allowed secret name.' >"$clean"
  "$CHECK" leak-scan "$clean" >/dev/null 2>&1 \
    || fail "leak scanner rejected a secret name without a value"

  canary='synthetic-canary-not-a-real-secret'
  printf '%s%s\n' 'DOPPLER_TOKEN=dp.st.' "$canary" >"$bad"
  rc=0
  out=$("$CHECK" leak-scan "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "leak scanner accepted a secret-shaped synthetic value"
  assert_contains "$out" "doppler-service-token" "leak scanner did not name the matched rule"
  assert_contains "$out" "$bad:1" "leak scanner did not report the location"
  assert_not_contains "$out" "$canary" "leak scanner echoed the matched value"
  pass "leak scanner rejects a synthetic value without echoing it"
}

test_public_entrypoint_validates_tracked_standard
test_policy_owner_has_one_precise_trigger
test_paid_oidc_remains_captain_owned_recommendation
test_schemas_and_example_are_publicly_validated
test_schema_patterns_and_unknown_fields_are_enforced
test_undocumented_exception_is_rejected
test_temporary_migration_requires_removal_contract
test_identity_and_exception_cross_fields_are_enforced
test_value_leak_scan_reports_rule_not_value
