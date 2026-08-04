#!/usr/bin/env bash
# Registered watcher check for the Mac-mini disk guard
# (fleet-local-disk-guard-o14).
#
# Usage: fm-disk-guard-poll.sh
#
# Prints one line when the data volume is below the configured floor:
#   disk-floor-breach <message>
# Prints nothing when free space is at or above the floor, or cannot be
# measured (bin/fm-disk-lib.sh fails open on an unreadable volume).
#
# This is the tracked poll body. bin/fm-bootstrap.sh's disk_guard_check_setup
# generates the registered state/disk-guard.check.sh wrapper that execs it
# with FM_HOME set and binds it through bin/fm-check-register.sh, following
# the same registered-check contract as bin/fm-better-stack-incidents-poll.sh.
# Unlike that poll, this one needs no external credential or dedupe state:
# fm-watch.sh's generic "check: $c: $out" path is the only consumer, so a
# breach simply re-wakes on every CHECK_INTERVAL sweep until space is
# reclaimed or the floor is raised.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-disk-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-disk-lib.sh"

if ! msg=$(fm_disk_floor_breach "$CONFIG"); then
  printf 'disk-floor-breach %s\n' "$msg"
fi
