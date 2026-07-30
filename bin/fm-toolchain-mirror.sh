#!/usr/bin/env bash
# fm-toolchain-mirror.sh - snapshot and restore the fleet-critical CLI toolchain.
#
# The mirror is platform-specific and contains complete installed npm package
# trees plus exact binary bytes for no-mistakes, Herdr, and Treehouse.
# Snapshot never updates a tool.
# Restore writes only to a new operator-selected prefix and never overwrites the
# ambient installation.
#
# Default mirror:
#   $FM_HOME/data/toolchain-mirror
#
# Usage:
#   fm-toolchain-mirror.sh snapshot [--mirror <directory>]
#   fm-toolchain-mirror.sh verify [--mirror <directory>] [--snapshot <id>]
#   fm-toolchain-mirror.sh restore [--mirror <directory>] [--snapshot <id>] \
#     --prefix <new-directory> [--tool <name>]
#   fm-toolchain-mirror.sh --help
#
# FM_TOOLCHAIN_MIRROR overrides the default mirror.
# FM_TOOLCHAIN_SNAPSHOT_ID provides a deterministic snapshot id for tests.
# FM_TOOLCHAIN_NPM_ROOT overrides `npm root -g` for isolated tests.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
MIRROR="${FM_TOOLCHAIN_MIRROR:-$FM_HOME/data/toolchain-mirror}"
SNAPSHOT=
PREFIX=
ONLY_TOOL=
TMP_PATH=

die() {
  printf 'fm-toolchain-mirror.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,20{s/^# \{0,1\}//;p;}' "$0"
}

cleanup() {
  if [ -n "$TMP_PATH" ] && [ -e "$TMP_PATH" ]; then
    rm -rf -- "$TMP_PATH"
  fi
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "need sha256sum or shasum to verify mirror artifacts"
  fi
}

validate_name() {
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) die "$1 contains unsupported characters: $2" ;;
  esac
}

validate_tool() {
  case "$1" in
    tasks-axi|gh-axi|lavish-axi|quota-axi|chrome-devtools-axi|no-mistakes|herdr|treehouse) ;;
    *) die "unsupported tool: $1" ;;
  esac
}

npm_bin_relative() {
  case "$1" in
    tasks-axi) printf '%s\n' 'dist/bin/tasks-axi.js' ;;
    gh-axi) printf '%s\n' 'dist/bin/gh-axi.js' ;;
    lavish-axi) printf '%s\n' 'dist/cli.mjs' ;;
    quota-axi) printf '%s\n' 'dist/bin/quota-axi.js' ;;
    chrome-devtools-axi) printf '%s\n' 'dist/bin/chrome-devtools-axi.js' ;;
    *) return 1 ;;
  esac
}

update_mechanism() {
  case "$1" in
    tasks-axi|gh-axi|lavish-axi|quota-axi|chrome-devtools-axi)
      printf 'npm update -g %s\n' "$1"
      ;;
    no-mistakes) printf '%s\n' 'no-mistakes update' ;;
    herdr) printf '%s\n' 'brew upgrade herdr (or herdr update)' ;;
    treehouse) printf '%s\n' 'treehouse update' ;;
  esac
}

version_from_output() {
  tool=$1
  output_file=$2
  case "$tool" in
    tasks-axi|gh-axi|lavish-axi|quota-axi|chrome-devtools-axi)
      tr -d '[:space:]' < "$output_file"
      ;;
    no-mistakes)
      awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^v[0-9]/) { print $i; exit } }' \
        "$output_file"
      ;;
    herdr)
      awk 'NR == 1 && $1 == "herdr" { print $2; exit }' "$output_file"
      ;;
    treehouse)
      tr -d '[:space:]' < "$output_file"
      ;;
  esac
}

resolve_executable() {
  perl -MCwd=abs_path -e \
    'my $path = abs_path($ARGV[0]); defined $path or exit 1; print $path' "$1"
}

parse_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mirror)
        [ "$#" -ge 2 ] || die "--mirror requires a directory"
        MIRROR=$2
        shift 2
        ;;
      --snapshot)
        [ "$#" -ge 2 ] || die "--snapshot requires an id"
        SNAPSHOT=$2
        shift 2
        ;;
      --prefix)
        [ "$#" -ge 2 ] || die "--prefix requires a new directory"
        PREFIX=$2
        shift 2
        ;;
      --tool)
        [ "$#" -ge 2 ] || die "--tool requires a tool name"
        ONLY_TOOL=$2
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

mirror_guard() {
  case "$MIRROR" in
    ''|/) die "refusing unsafe mirror path: ${MIRROR:-<empty>}" ;;
  esac
}

resolve_snapshot() {
  if [ -z "$SNAPSHOT" ]; then
    [ -f "$MIRROR/current" ] || die "mirror has no current snapshot: $MIRROR"
    IFS= read -r SNAPSHOT < "$MIRROR/current" || true
  fi
  validate_name "snapshot id" "$SNAPSHOT"
  SNAPSHOT_DIR="$MIRROR/snapshots/$SNAPSHOT"
  [ -d "$SNAPSHOT_DIR" ] || die "snapshot does not exist: $SNAPSHOT_DIR"
  [ -f "$SNAPSHOT_DIR/manifest.tsv" ] || die "snapshot manifest is missing: $SNAPSHOT_DIR/manifest.tsv"
}

snapshot_tool() {
  tool=$1
  kind=$2
  command_path=$(command -v "$tool" 2>/dev/null) || die "$tool is not installed"
  version_file="versions/$tool.txt"
  if ! "$command_path" --version > "$TMP_PATH/$version_file" 2>&1; then
    die "$tool --version failed"
  fi
  version=$(version_from_output "$tool" "$TMP_PATH/$version_file")
  [ -n "$version" ] || die "could not parse $tool --version"

  if [ "$kind" = npm ]; then
    package_dir="$NPM_ROOT/$tool"
    [ -f "$package_dir/package.json" ] || die "installed npm package is missing: $package_dir"
    package_version=$(node -p 'require(process.argv[1]).version' "$package_dir/package.json")
    [ "$version" = "$package_version" ] \
      || die "$tool --version reported $version but package.json records $package_version"
    artifact="artifacts/npm/$tool.tar.gz"
    tar -czf "$TMP_PATH/$artifact" -C "$NPM_ROOT" "$tool"
    source="npm-global:$package_dir"
  else
    resolved=$(resolve_executable "$command_path") || die "could not resolve $command_path"
    artifact="artifacts/bin/$tool"
    install -m 0755 "$resolved" "$TMP_PATH/$artifact"
    source="binary:$resolved"
  fi

  checksum=$(sha256_file "$TMP_PATH/$artifact")
  mechanism=$(update_mechanism "$tool")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tool" "$kind" "$version" "$version_file" "$artifact" "$checksum" "$source" "$mechanism" \
    >> "$TMP_PATH/manifest.tsv"
}

snapshot_action() {
  [ -z "$SNAPSHOT" ] || die "--snapshot is not valid with snapshot"
  [ -z "$PREFIX" ] || die "--prefix is not valid with snapshot"
  [ -z "$ONLY_TOOL" ] || die "--tool is not valid with snapshot"
  mirror_guard
  command -v node >/dev/null 2>&1 || die "node is required to snapshot npm packages"
  command -v npm >/dev/null 2>&1 || die "npm is required to locate global packages"
  command -v perl >/dev/null 2>&1 || die "perl is required to resolve installed binaries"

  NPM_ROOT="${FM_TOOLCHAIN_NPM_ROOT:-$(npm root -g)}"
  [ -d "$NPM_ROOT" ] || die "npm global root does not exist: $NPM_ROOT"

  snapshot_id="${FM_TOOLCHAIN_SNAPSHOT_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(uname -s)-$(uname -m)}"
  validate_name "snapshot id" "$snapshot_id"
  mkdir -p "$MIRROR/snapshots"
  final="$MIRROR/snapshots/$snapshot_id"
  [ ! -e "$final" ] || die "snapshot already exists: $final"

  TMP_PATH=$(mktemp -d "$MIRROR/.snapshot.XXXXXX") || die "could not create mirror staging directory"
  mkdir -p "$TMP_PATH/artifacts/npm" "$TMP_PATH/artifacts/bin" "$TMP_PATH/versions"
  printf 'tool\tkind\tversion\tversion_file\tartifact\tsha256\tinstall_source\tupdate_mechanism\n' \
    > "$TMP_PATH/manifest.tsv"
  printf 'schema\tfm-toolchain-mirror.v1\nos\t%s\narch\t%s\n' "$(uname -s)" "$(uname -m)" \
    > "$TMP_PATH/platform.tsv"

  snapshot_tool tasks-axi npm
  snapshot_tool gh-axi npm
  snapshot_tool lavish-axi npm
  snapshot_tool quota-axi npm
  snapshot_tool chrome-devtools-axi npm
  snapshot_tool no-mistakes binary
  snapshot_tool herdr binary
  snapshot_tool treehouse binary

  mv "$TMP_PATH" "$final"
  TMP_PATH=
  current_tmp=$(mktemp "$MIRROR/.current.XXXXXX") || die "could not create current marker"
  TMP_PATH=$current_tmp
  printf '%s\n' "$snapshot_id" > "$current_tmp"
  mv "$current_tmp" "$MIRROR/current"
  TMP_PATH=

  printf 'snapshot: %s\n' "$snapshot_id"
  printf 'mirror: %s\n' "$MIRROR"
  printf 'manifest: %s\n' "$final/manifest.tsv"
  printf 'artifacts: 8\n'
}

verify_archive_shape() {
  tool=$1
  artifact_path=$2
  if ! tar -tzf "$artifact_path" | awk -v prefix="$tool/" '
      index($0, prefix) != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ { bad = 1 }
      END { exit bad }
    '; then
    die "npm archive has an unsafe or unexpected path: $artifact_path"
  fi
}

verify_manifest() {
  manifest=$1
  expected_header='tool	kind	version	version_file	artifact	sha256	install_source	update_mechanism'
  IFS= read -r actual_header < "$manifest" || true
  [ "$actual_header" = "$expected_header" ] || die "snapshot manifest header is invalid"
  expected_schema=$(awk -F '\t' '$1 == "schema" { print $2; exit }' "$SNAPSHOT_DIR/platform.tsv")
  [ "$expected_schema" = "fm-toolchain-mirror.v1" ] \
    || die "unsupported snapshot schema: ${expected_schema:-<empty>}"
  expected_os=$(awk -F '\t' '$1 == "os" { print $2; exit }' "$SNAPSHOT_DIR/platform.tsv")
  expected_arch=$(awk -F '\t' '$1 == "arch" { print $2; exit }' "$SNAPSHOT_DIR/platform.tsv")
  [ "$expected_os" = "$(uname -s)" ] \
    || die "snapshot OS $expected_os does not match $(uname -s)"
  [ "$expected_arch" = "$(uname -m)" ] \
    || die "snapshot architecture $expected_arch does not match $(uname -m)"

  found=0
  seen=' '
  tab=$(printf '\t')
  while IFS="$tab" read -r tool kind version version_file artifact checksum source mechanism \
    || [ -n "${tool:-}" ]; do
    [ "$tool" != tool ] || continue
    [ -n "$tool" ] || continue
    validate_tool "$tool"
    case "$seen" in
      *" $tool "*) die "snapshot manifest contains duplicate tool: $tool" ;;
    esac
    seen="$seen$tool "
    if [ -n "$ONLY_TOOL" ] && [ "$tool" != "$ONLY_TOOL" ]; then
      continue
    fi
    [ "$version_file" = "versions/$tool.txt" ] \
      || die "unexpected version output path for $tool: $version_file"
    case "$kind" in
      npm) expected_artifact="artifacts/npm/$tool.tar.gz" ;;
      binary) expected_artifact="artifacts/bin/$tool" ;;
      *) die "unsupported artifact kind for $tool: $kind" ;;
    esac
    [ "$artifact" = "$expected_artifact" ] \
      || die "unexpected artifact path for $tool: $artifact"
    artifact_path="$SNAPSHOT_DIR/$artifact"
    [ -f "$artifact_path" ] || die "artifact is missing: $artifact_path"
    actual=$(sha256_file "$artifact_path")
    [ "$actual" = "$checksum" ] \
      || die "checksum mismatch for $tool (expected $checksum, got $actual)"
    output_path="$SNAPSHOT_DIR/$version_file"
    [ -f "$output_path" ] || die "version output is missing for $tool"
    recorded_version=$(version_from_output "$tool" "$output_path")
    [ "$recorded_version" = "$version" ] \
      || die "version output for $tool reports $recorded_version, expected $version"
    case "$kind" in
      npm) verify_archive_shape "$tool" "$artifact_path" ;;
      binary) ;;
    esac
    [ -n "$version" ] && [ -n "$source" ] && [ -n "$mechanism" ] \
      || die "manifest metadata is incomplete for $tool"
    found=$((found + 1))
  done < "$manifest"
  if [ -n "$ONLY_TOOL" ]; then
    [ "$found" -eq 1 ] || die "snapshot does not contain requested tool: $ONLY_TOOL"
  else
    [ "$found" -eq 8 ] || die "snapshot contains $found tools; expected all 8"
  fi
  VERIFIED_COUNT=$found
}

verify_action() {
  [ -z "$PREFIX" ] || die "--prefix is not valid with verify"
  if [ -n "$ONLY_TOOL" ]; then
    validate_tool "$ONLY_TOOL"
  fi
  mirror_guard
  resolve_snapshot
  [ -f "$SNAPSHOT_DIR/platform.tsv" ] || die "snapshot platform metadata is missing"
  verify_manifest "$SNAPSHOT_DIR/manifest.tsv"
  printf 'verified: %s (%s artifacts)\n' "$SNAPSHOT_DIR" "$VERIFIED_COUNT"
}

restore_action() {
  [ -n "$PREFIX" ] || die "restore requires --prefix <new-directory>"
  case "$PREFIX" in
    ''|/) die "refusing unsafe restore prefix: ${PREFIX:-<empty>}" ;;
  esac
  [ ! -e "$PREFIX" ] || die "restore prefix already exists; choose a new directory: $PREFIX"
  if [ -n "$ONLY_TOOL" ]; then
    validate_tool "$ONLY_TOOL"
  fi
  mirror_guard
  resolve_snapshot
  [ -f "$SNAPSHOT_DIR/platform.tsv" ] || die "snapshot platform metadata is missing"
  verify_manifest "$SNAPSHOT_DIR/manifest.tsv"

  prefix_parent=$(dirname "$PREFIX")
  mkdir -p "$prefix_parent"
  TMP_PATH=$(mktemp -d "$prefix_parent/.fm-toolchain-restore.XXXXXX") \
    || die "could not create restore staging directory"
  mkdir -p "$TMP_PATH/bin" "$TMP_PATH/lib/node_modules"

  tab=$(printf '\t')
  restored=0
  while IFS="$tab" read -r tool kind version version_file artifact checksum source mechanism \
    || [ -n "${tool:-}" ]; do
    [ "$tool" != tool ] || continue
    [ -n "$tool" ] || continue
    if [ -n "$ONLY_TOOL" ] && [ "$tool" != "$ONLY_TOOL" ]; then
      continue
    fi
    artifact_path="$SNAPSHOT_DIR/$artifact"
    if [ "$kind" = npm ]; then
      tar -xzf "$artifact_path" -C "$TMP_PATH/lib/node_modules"
      bin_relative=$(npm_bin_relative "$tool")
      [ -f "$TMP_PATH/lib/node_modules/$tool/$bin_relative" ] \
        || die "restored npm package lacks $bin_relative: $tool"
      ln -s "../lib/node_modules/$tool/$bin_relative" "$TMP_PATH/bin/$tool"
    else
      install -m 0755 "$artifact_path" "$TMP_PATH/bin/$tool"
    fi
    if ! "$TMP_PATH/bin/$tool" --version > "$TMP_PATH/$tool.version" 2>&1; then
      die "restored $tool --version failed"
    fi
    restored_version=$(version_from_output "$tool" "$TMP_PATH/$tool.version")
    [ "$restored_version" = "$version" ] \
      || die "restored $tool reported $restored_version, expected $version"
    rm "$TMP_PATH/$tool.version"
    restored=$((restored + 1))
  done < "$SNAPSHOT_DIR/manifest.tsv"

  [ "$restored" -eq "$VERIFIED_COUNT" ] || die "restored $restored of $VERIFIED_COUNT verified artifacts"
  mv "$TMP_PATH" "$PREFIX"
  TMP_PATH=
  printf 'restored: %s (%s tools)\n' "$PREFIX" "$restored"
  printf 'activate: prepend %s/bin to PATH\n' "$PREFIX"
}

ACTION=${1:-}
case "$ACTION" in
  snapshot|verify|restore)
    shift
    parse_options "$@"
    "${ACTION}_action"
    ;;
  --help|-h|'')
    usage
    ;;
  *)
    die "unknown action: $ACTION"
    ;;
esac
