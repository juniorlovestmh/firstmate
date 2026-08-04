#!/usr/bin/env bash
# Validate or deploy the tracked fleet-wide Steampipe GCP connection inventory.
# Usage: fm-fleet-inventory-configure.sh [--check] [--config PATH] [--help]
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly DEFAULT_CONFIG="$ROOT_DIR/docs/examples/fleet-inventory-gcp.spc"
readonly RUNNER="${FLEET_INVENTORY_RUNNER:-ubuntu@192.168.1.120}"
readonly SSH_KEY="${FLEET_INVENTORY_SSH_KEY:-/Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key}"

usage() {
  cat <<'EOF'
Usage: fm-fleet-inventory-configure.sh [--check] [--config PATH] [--help]

Validate or atomically deploy the tracked fleet-wide Steampipe GCP connection inventory.
Deployment restarts only the fleet-inventory services in dependency order and verifies
the loopback Powerpipe root and multi-project dashboard endpoints without launching
another Steampipe process.

Environment:
  FLEET_INVENTORY_RUNNER   SSH destination (default: ubuntu@192.168.1.120)
  FLEET_INVENTORY_SSH_KEY  SSH identity path
EOF
}

die() {
  printf 'fm-fleet-inventory-configure.sh: %s\n' "$*" >&2
  exit 1
}

mode=deploy
config=$DEFAULT_CONFIG
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      mode=check
      shift
      ;;
    --config)
      [ "$#" -ge 2 ] || die "--config requires a path"
      config=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

validate_config() {
  local aggregator_connections aggregator_count disabled_ignore_count project_count unique_count
  local project_connections projects

  [ -r "$config" ] || die "config is not readable: $config"
  grep -Fq 'connection "gcp_all"' "$config" || die "config has no gcp_all aggregator"
  project_connections=$(awk '
    /^connection "[^"]+"/ {
      name = $2
      gsub(/"/, "", name)
      in_connection = 1
      next
    }
    /^}/ { in_connection = 0 }
    in_connection && $1 == "project" && $2 == "=" {
      project = $3
      gsub(/"/, "", project)
      print name "\t" project
    }
  ' "$config")
  projects=$(printf '%s\n' "$project_connections" | awk -F '\t' 'NF == 2 { print $2 }')
  aggregator_connections=$(awk '
    /^connection "gcp_all"/ { in_aggregator = 1; next }
    in_aggregator && /^}/ { in_aggregator = 0 }
    in_aggregator && $1 ~ /^"[^"]+"[,]?$/ {
      connection = $1
      gsub(/[",]/, "", connection)
      print connection
    }
  ' "$config")
  project_count=$(printf '%s\n' "$projects" | awk 'NF { count++ } END { print count + 0 }')
  unique_count=$(printf '%s\n' "$projects" | awk 'NF' | sort -u | awk 'END { print NR + 0 }')
  aggregator_count=$(printf '%s\n' "$aggregator_connections" | awk 'NF { count++ } END { print count + 0 }')
  disabled_ignore_count=$(grep -Fc '".*SERVICE_DISABLED.*"' "$config")
  [ "$project_count" -gt 0 ] || die "config has no project connections"
  [ "$project_count" -eq "$unique_count" ] || die "config contains duplicate project IDs"
  [ "$project_count" -eq "$aggregator_count" ] \
    || die "gcp_all aggregator must include every project connection"
  [ "$project_count" -eq "$disabled_ignore_count" ] \
    || die "every project connection must ignore disabled service APIs"
  while IFS=$'\t' read -r connection project; do
    [ -n "$connection" ] || continue
    grep -Fxq "$connection" <<<"$aggregator_connections" \
      || die "gcp_all aggregator is missing connection: $connection ($project)"
  done <<<"$project_connections"
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    printf 'fleet-inventory config project: %s\n' "$project"
  done <<EOF
$projects
EOF
  printf '%s\n' 'fleet-inventory config: disabled APIs ignored'
  printf 'fleet-inventory config: %s projects\n' "$project_count"
}

validate_config
[ "$mode" = check ] && exit 0
[ -r "$SSH_KEY" ] || die "SSH identity is not readable: $SSH_KEY"

ssh_args=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes)

ssh "${ssh_args[@]}" "$RUNNER" \
  'sudo install -m 0644 -o fleet-inventory -g fleet-inventory /dev/stdin /var/lib/fleet-inventory/steampipe/config/gcp.spc.next' \
  <"$config"

ssh "${ssh_args[@]}" "$RUNNER" 'sudo bash -s' <<'REMOTE'
set -Eeuo pipefail

readonly current=/var/lib/fleet-inventory/steampipe/config/gcp.spc
readonly next=/var/lib/fleet-inventory/steampipe/config/gcp.spc.next
readonly previous=/var/lib/fleet-inventory/steampipe/config/gcp.spc.previous
changed=0

assert_no_orphan_plugin_manager() {
  local cgroup pid pid_cgroup
  cgroup=$(systemctl show fleet-inventory.steampipe.service -p ControlGroup --value)
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    pid_cgroup=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup" 2>/dev/null || true)
    case "$pid_cgroup" in
      "$cgroup"|"$cgroup"/*) ;;
      *)
        printf 'orphan Steampipe plugin manager pid %s is outside %s; stop the competing Steampipe process before deployment\n' \
          "$pid" "$cgroup" >&2
        return 1
        ;;
    esac
  done < <(pgrep -f '^/usr/local/bin/steampipe plugin-manager --install-dir /var/lib/fleet-inventory/steampipe$' || true)
}

wait_for_steampipe() {
  local attempt consecutive=0
  for attempt in $(seq 1 45); do
    if systemctl is-active --quiet fleet-inventory.steampipe.service \
      && ss -ltnH | awk '$4 ~ /:9193$/ { found = 1 } END { exit !found }'; then
      consecutive=$((consecutive + 1))
      [ "$consecutive" -ge 5 ] && return 0
    else
      consecutive=0
    fi
    sleep 1
  done
  return 1
}

wait_for_powerpipe() {
  local attempt consecutive=0
  for attempt in $(seq 1 45); do
    if systemctl is-active --quiet fleet-inventory.powerpipe.service; then
      consecutive=$((consecutive + 1))
      [ "$consecutive" -ge 5 ] && return 0
    else
      consecutive=0
    fi
    sleep 1
  done
  return 1
}

assert_loopback_listeners() {
  local actual expected
  expected=$'127.0.0.1:9033\n127.0.0.1:9193\n[::1]:9193'
  actual=$(ss -ltnH | awk '$4 ~ /:9033$/ || $4 ~ /:9193$/ { print $4 }' | sort -u)
  [ "$actual" = "$expected" ] || {
    printf 'unexpected fleet-inventory listeners:\n%s\n' "$actual" >&2
    return 1
  }
}

wait_for_dashboard() {
  local attempt code url=$1
  for attempt in $(seq 1 60); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)
    [ "$code" = 200 ] && return 0
    sleep 1
  done
  return 1
}

restart_inventory_services() {
  systemctl stop fleet-inventory.powerpipe.service
  systemctl restart fleet-inventory.steampipe.service
  wait_for_steampipe
  systemctl start fleet-inventory.powerpipe.service
  wait_for_powerpipe
  assert_loopback_listeners
  wait_for_dashboard http://127.0.0.1:9033/
}

rollback() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$changed" -eq 1 ] && [ -f "$previous" ]; then
      install -m 0644 -o fleet-inventory -g fleet-inventory "$previous" "$current"
    fi
    restart_inventory_services || true
  fi
  rm -f "$next"
  exit "$status"
}
trap rollback EXIT

test -s "$next"
grep -Fq 'connection "gcp_all"' "$next"
grep -Fq '/var/lib/fleet-inventory/gcp-reader.json' "$next"
assert_no_orphan_plugin_manager

if cmp -s "$next" "$current"; then
  rm -f "$next"
  printf '%s\n' 'fleet-inventory config unchanged'
else
  install -m 0644 -o fleet-inventory -g fleet-inventory "$current" "$previous"
  mv -f "$next" "$current"
  changed=1
fi

restart_inventory_services
printf '%s\n' 'powerpipe_root_http=200'
curl -fsS -o /dev/null -w 'powerpipe_project_report_http=%{http_code}\n' \
  --max-time 10 \
  http://127.0.0.1:9033/gcp_insights.dashboard.project_report
changed=0
printf '%s\n' 'fleet-inventory config deployment: ok'
REMOTE
