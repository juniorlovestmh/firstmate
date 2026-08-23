#!/usr/bin/env bash
# Public-interface behavior tests for the home-private estate seed helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED="$ROOT/bin/fm-estate-seed.sh"
COMPILE="$ROOT/bin/fm-estate-compile.sh"
TMP_ROOT=$(fm_test_tmproot fm-estate-seed)

test_seed_writes_known_truth_and_registry_modes_once() {
  local home="$TMP_ROOT/home" catalog="$TMP_ROOT/catalog" out rc before after
  mkdir -p "$home/data"
  cat >"$home/data/projects.md" <<'MD'
# Projects

- alpha [no-mistakes +yolo] - Alpha project (added 2026-08-01)
- beta [local-only] - Beta project; base branch: beta (added 2026-08-02)
- legacy - Legacy default mode project (added 2026-08-03)
MD

  FM_HOME="$home" FM_ESTATE_CATALOG_DIR="$catalog" \
    "$SEED" --collected-at 2026-08-09T00:00:00Z >/dev/null \
    || fail "estate seed failed"
  FM_ESTATE_CATALOG_DIR="$catalog" FM_ESTATE_NOW=2026-08-10T00:00:00Z \
    "$COMPILE" >/dev/null || fail "seeded estate did not compile"

  jq -e '
    ([.entities[] | select(.kind == "host") | .id] | sort) ==
      ["gh-runner-t1", "pier-trackway", "pve", "woodpecker-ci"] and
    ([.entities[] | select(.kind == "dns") | .name] | sort) ==
      ["ci-agent.appheat.co", "ci.appheat.co"] and
    ([.entities[] | select(.kind == "repository") | {id, delivery_mode}] | sort_by(.id)) ==
      [{"id":"alpha","delivery_mode":"no-mistakes"},{"id":"beta","delivery_mode":"local-only"},{"id":"legacy","delivery_mode":"no-mistakes"}]
  ' "$catalog/compiled/estate.json" >/dev/null \
    || fail "seed omitted known hosts, DNS names, or registry delivery modes"

  before=$(find "$catalog/declared" -type f -name '*.yaml' -exec shasum -a 256 {} + | sort | shasum -a 256)
  set +e
  out=$(FM_HOME="$home" FM_ESTATE_CATALOG_DIR="$catalog" \
    "$SEED" --collected-at 2026-08-10T00:00:00Z 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "seed overwrote an existing declared catalog"
  assert_contains "$out" "declared catalog already contains YAML" \
    "seed overwrite refusal was not actionable"
  after=$(find "$catalog/declared" -type f -name '*.yaml' -exec shasum -a 256 {} + | sort | shasum -a 256)
  [ "$before" = "$after" ] || fail "failed second seed changed declared truth"
  pass "estate seed writes the accepted initial truth once and never overwrites it"
}

test_seed_writes_known_truth_and_registry_modes_once
