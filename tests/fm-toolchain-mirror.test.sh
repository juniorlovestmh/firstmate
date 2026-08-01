#!/usr/bin/env bash
# Contract and behavior tests for the offline toolchain mirror.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIRROR_SCRIPT="$ROOT/bin/fm-toolchain-mirror.sh"
assert_present "$MIRROR_SCRIPT" "bin/fm-toolchain-mirror.sh is missing"
[ -x "$MIRROR_SCRIPT" ] || fail "fm-toolchain-mirror.sh must be executable"
TMP_ROOT=$(fm_test_tmproot fm-toolchain-mirror)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_version_tool() {
  path=$1
  output=$2
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf '\''%%s\\n'\'' '\''%s'\''\n' "$output"
  } > "$path"
  chmod +x "$path"
}

make_npm_tool() {
  tool=$1
  version=$2
  bin_relative=$3
  package_dir="$CASE_DIR/npm-root/$tool"
  mkdir -p "$package_dir/$(dirname "$bin_relative")" "$package_dir/node_modules/example-dependency"
  cat > "$package_dir/package.json" <<EOF
{"name":"$tool","version":"$version","bin":{"$tool":"$bin_relative"}}
EOF
  cat > "$package_dir/$bin_relative" <<EOF
#!/usr/bin/env node
console.log("$version");
EOF
  chmod +x "$package_dir/$bin_relative"
  printf '%s\n' 'offline dependency proof' > "$package_dir/node_modules/example-dependency/proof.txt"
  ln -s "$package_dir/$bin_relative" "$CASE_DIR/fakebin/$tool"
}

setup_case() {
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/fakebin" "$CASE_DIR/npm-root"
  make_npm_tool tasks-axi 0.2.3 dist/bin/tasks-axi.js
  make_npm_tool gh-axi 0.1.27 lib/custom-gh-entry.js
  make_npm_tool lavish-axi 0.1.42 dist/cli.mjs
  make_npm_tool quota-axi 0.1.16 dist/bin/quota-axi.js
  make_npm_tool chrome-devtools-axi 0.1.26 dist/bin/chrome-devtools-axi.js
  make_version_tool "$CASE_DIR/fakebin/no-mistakes" \
    'no-mistakes version v1.40.3 (test) 2026-07-22T01:41:55Z'
  make_version_tool "$CASE_DIR/fakebin/herdr" 'herdr 0.7.5'
  make_version_tool "$CASE_DIR/fakebin/treehouse" 'v2.1.0'
}

test_snapshot_and_offline_restore() {
  setup_case snapshot-restore
  mirror="$CASE_DIR/mirror"
  restore="$CASE_DIR/restored"
  out=$(PATH="$CASE_DIR/fakebin:$PATH" \
    FM_TOOLCHAIN_NPM_ROOT="$CASE_DIR/npm-root" \
    FM_TOOLCHAIN_SNAPSHOT_ID=test-snapshot \
    "$MIRROR_SCRIPT" snapshot --mirror "$mirror") || fail "snapshot command failed"

  assert_contains "$out" "snapshot: test-snapshot" "snapshot must report its id"
  assert_contains "$out" "artifacts: 8" "snapshot must contain all eight tools"
  assert_present "$mirror/current" "snapshot must publish the current marker"
  assert_present "$mirror/snapshots/test-snapshot/manifest.tsv" "snapshot must publish a manifest"
  assert_present "$mirror/snapshots/test-snapshot/versions/no-mistakes.txt" \
    "snapshot must retain raw version output"
  assert_contains "$(cat "$mirror/snapshots/test-snapshot/versions/no-mistakes.txt")" \
    "no-mistakes version v1.40.3" "raw version output must be preserved"

  verify_out=$("$MIRROR_SCRIPT" verify --mirror "$mirror") || fail "verify command failed"
  assert_contains "$verify_out" "(8 artifacts)" "verify must check every artifact"

  restore_out=$("$MIRROR_SCRIPT" restore --mirror "$mirror" --prefix "$restore") \
    || fail "restore command failed"
  assert_contains "$restore_out" "(8 tools)" "restore must reinstall every tool"
  assert_present "$restore/bin/no-mistakes" "restore must install binary tools"
  assert_present "$restore/lib/node_modules/lavish-axi/node_modules/example-dependency/proof.txt" \
    "restore must retain installed npm dependencies for offline use"
  [ "$("$restore/bin/tasks-axi" --version)" = "0.2.3" ] \
    || fail "restored tasks-axi must report the pinned version"
  [ "$("$restore/bin/treehouse" --version)" = "v2.1.0" ] \
    || fail "restored treehouse must report the pinned version"
  pass "snapshot and restore preserve all pinned tools offline"
}

test_restore_refuses_existing_prefix() {
  setup_case existing-prefix
  mirror="$CASE_DIR/mirror"
  PATH="$CASE_DIR/fakebin:$PATH" \
    FM_TOOLCHAIN_NPM_ROOT="$CASE_DIR/npm-root" \
    FM_TOOLCHAIN_SNAPSHOT_ID=test-snapshot \
    "$MIRROR_SCRIPT" snapshot --mirror "$mirror" >/dev/null \
    || fail "snapshot setup failed"
  mkdir -p "$CASE_DIR/existing"
  if "$MIRROR_SCRIPT" restore --mirror "$mirror" --prefix "$CASE_DIR/existing" \
    >"$CASE_DIR/restore.out" 2>"$CASE_DIR/restore.err"; then
    fail "restore must refuse an existing prefix"
  fi
  assert_contains "$(cat "$CASE_DIR/restore.err")" "restore prefix already exists" \
    "restore refusal must explain how to recover safely"
  pass "restore refuses to overwrite an existing installation"
}

test_verify_rejects_tampered_artifact() {
  setup_case tampered-artifact
  mirror="$CASE_DIR/mirror"
  PATH="$CASE_DIR/fakebin:$PATH" \
    FM_TOOLCHAIN_NPM_ROOT="$CASE_DIR/npm-root" \
    FM_TOOLCHAIN_SNAPSHOT_ID=test-snapshot \
    "$MIRROR_SCRIPT" snapshot --mirror "$mirror" >/dev/null \
    || fail "snapshot setup failed"
  printf '%s\n' 'tamper' >> "$mirror/snapshots/test-snapshot/artifacts/bin/treehouse"
  if "$MIRROR_SCRIPT" verify --mirror "$mirror" >"$CASE_DIR/verify.out" 2>"$CASE_DIR/verify.err"; then
    fail "verify must reject a tampered artifact"
  fi
  assert_contains "$(cat "$CASE_DIR/verify.err")" "checksum mismatch for treehouse" \
    "tamper refusal must name the affected tool"
  pass "verify rejects changed mirror bytes"
}

test_snapshot_and_offline_restore
test_restore_refuses_existing_prefix
test_verify_rejects_tampered_artifact
