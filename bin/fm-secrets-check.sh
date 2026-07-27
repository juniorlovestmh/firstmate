#!/usr/bin/env bash
# Validate Firstmate's tracked secrets standard and project manifests without
# reading or printing secret values.
#
# Usage:
#   fm-secrets-check.sh
#   fm-secrets-check.sh standard
#   fm-secrets-check.sh manifest <docs/secrets-policy.json>
#   fm-secrets-check.sh inventory <project-dir>
#   fm-secrets-check.sh leak-scan <path> [path...]
#   fm-secrets-check.sh --help
#
# The default "standard" command validates both JSON schemas, the project
# example, the exact eight-project rollout, policy ownership pointers, and a
# value-leak scan over every tracked standard artifact.
#
# "manifest" validates one project declaration against the deterministic
# contract represented by docs/secrets-policy.schema.json.
#
# "inventory" is a read-only project-intake helper. It reads git-tracked
# filenames and classifies Doppler, GitHub secret-context, and OIDC references.
# It never reads untracked files and never prints matched source lines.
#
# "leak-scan" reports only "<path>:<line>: <rule>"; matching text is never
# echoed. It is intentionally high-confidence and complements, rather than
# replaces, provider-side secret scanning.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

command -v node >/dev/null 2>&1 || {
  echo "fm-secrets-check: node is required" >&2
  exit 2
}

exec node "$SCRIPT_DIR/fm-secrets-check.mjs" "$@"
