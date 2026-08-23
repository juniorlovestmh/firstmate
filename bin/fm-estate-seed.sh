#!/usr/bin/env bash
# Seed a fresh home-private declared estate catalog from accepted fleet truth and projects.md.
# Usage: fm-estate-seed.sh [--catalog PATH] [--projects PATH] [--collected-at UTC]
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
readonly ROOT_DIR
FM_HOME=${FM_HOME:-$ROOT_DIR}
catalog=${FM_ESTATE_CATALOG_DIR:-$FM_HOME/data/estate-catalog}
projects=${FM_ESTATE_PROJECTS_FILE:-$FM_HOME/data/projects.md}
collected_at=${FM_ESTATE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

usage() {
  cat <<'EOF'
Usage: fm-estate-seed.sh [--catalog PATH] [--projects PATH] [--collected-at UTC]

Write the accepted initial declared estate plus registered repository delivery
modes. This helper is bootstrap-only: it refuses when declared YAML already
exists and never writes compiled output.

Environment:
  FM_HOME                 Firstmate home containing data/projects.md
  FM_ESTATE_CATALOG_DIR   Exact catalog directory override
  FM_ESTATE_PROJECTS_FILE Exact projects.md override
  FM_ESTATE_NOW           UTC collection time for reproducible seeding
EOF
}

die() {
  printf 'fm-estate-seed.sh: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog)
      [ "$#" -ge 2 ] || die "--catalog requires a path"
      catalog=$2
      shift 2
      ;;
    --projects)
      [ "$#" -ge 2 ] || die "--projects requires a path"
      projects=$2
      shift 2
      ;;
    --collected-at)
      [ "$#" -ge 2 ] || die "--collected-at requires a UTC timestamp"
      collected_at=$2
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

[ -r "$projects" ] || die "project registry is not readable: $projects"
command -v ruby >/dev/null 2>&1 || die "ruby is required to write catalog YAML safely"
mkdir -p "$catalog"

ruby - "$catalog" "$projects" "$collected_at" <<'RUBY'
require "fileutils"
require "tmpdir"
require "time"
require "yaml"

PROGRAM = "fm-estate-seed.sh"
UTC_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
MODES = %w[no-mistakes direct-PR local-only].freeze

def fail!(message)
  warn "#{PROGRAM}: #{message}"
  exit 1
end

def entity(fields, collected_at, authority)
  fields.merge(
    "source" => "declarative",
    "collected_at" => collected_at,
    "authority" => authority
  )
end

def document(kind, entities)
  {"schema_version" => 1, "kind" => kind, "entities" => entities}
end

catalog, projects_path, collected_at = ARGV
fail!("collected time must be UTC as YYYY-MM-DDTHH:MM:SSZ") unless UTC_PATTERN.match?(collected_at)
Time.iso8601(collected_at)
declared = File.join(catalog, "declared")
existing = Dir.glob(File.join(declared, "**", "*.{yaml,yml}"))
fail!("declared catalog already contains YAML: #{declared}") unless existing.empty?

repositories = []
File.foreach(projects_path) do |line|
  match = line.match(/^\s*-\s+([A-Za-z0-9._-]+)(?:\s+\[([^\]]+)\])?\s+-\s+(.+)$/)
  next unless match
  name, flags, description = match.captures
  mode = "no-mistakes"
  if flags
    candidate = flags.split.find { |flag| !flag.start_with?("+") }
    mode = candidate if candidate
  end
  fail!("unsupported delivery mode #{mode.inspect} for #{name}") unless MODES.include?(mode)
  github = description[/canonical remote(?: is)?\s+([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)/i, 1] || "unknown"
  base_branch = description[/base branch:\s*([A-Za-z0-9._\/-]+)/i, 1] || "unknown"
  repositories << entity(
    {
      "id" => name,
      "github" => github,
      "delivery_mode" => mode,
      "verify_cmd" => "unknown",
      "ci" => "unknown",
      "base_branch" => base_branch
    },
    collected_at,
    "fm-estate-seed.sh:data/projects.md"
  )
end
fail!("project registry contains no project entries: #{projects_path}") if repositories.empty?
repositories.sort_by! { |repository| repository.fetch("id") }

design_authority = "fm-estate-seed.sh:accepted-agent-factory-design"
files = {
  "systems.yaml" => document("system", [
    entity({"id" => "bible-agents-staging", "owner" => "captain", "product" => "Bible Agents", "lifecycle" => "active"}, collected_at, design_authority),
    entity({"id" => "fleet-ci", "owner" => "captain", "product" => "Woodpecker", "lifecycle" => "active"}, collected_at, design_authority),
    entity({"id" => "fleet-inventory", "owner" => "captain", "product" => "Powerpipe", "lifecycle" => "active"}, collected_at, design_authority)
  ]),
  "repos.yaml" => document("repository", repositories),
  "compute.yaml" => document("host", [
    entity({"id" => "pve", "provider" => "proxmox", "ip" => "192.168.1.100", "role" => "hypervisor", "ssh_path" => "root@192.168.1.100"}, collected_at, design_authority),
    entity({"id" => "woodpecker-ci", "provider" => "proxmox", "vmid" => 110, "ip" => "192.168.1.112", "role" => "ci", "ssh_path" => "ubuntu@192.168.1.112"}, collected_at, design_authority),
    entity({"id" => "gh-runner-t1", "provider" => "proxmox", "vmid" => 120, "ip" => "192.168.1.120", "role" => "inventory and runner", "ssh_path" => "ubuntu@192.168.1.120"}, collected_at, design_authority),
    entity({"id" => "pier-trackway", "provider" => "exe.dev", "ip" => "unknown", "role" => "staging application host", "ssh_path" => "pier-trackway"}, collected_at, design_authority)
  ]),
  "services.yaml" => document("service", [
    entity({"id" => "woodpecker", "system" => "fleet-ci", "host" => "woodpecker-ci", "url" => "https://ci.appheat.co", "health_url" => "https://ci.appheat.co/healthz", "deploy_path" => "/home/deploy/woodpecker"}, collected_at, design_authority),
    entity({"id" => "fleet-powerpipe", "system" => "fleet-inventory", "host" => "gh-runner-t1", "url" => "http://127.0.0.1:9033", "deploy_path" => "/var/lib/fleet-inventory"}, collected_at, design_authority),
    entity({"id" => "bible-agents-staging", "system" => "bible-agents-staging", "host" => "pier-trackway", "url" => "https://pier-trackway.exe.xyz", "health_url" => "https://pier-trackway.exe.xyz/v1/health", "deploy_path" => "unknown"}, collected_at, design_authority)
  ]),
  "ci.yaml" => document("ci", [
    entity({"id" => "woodpecker", "product" => "woodpecker", "host" => "woodpecker-ci", "url" => "https://ci.appheat.co", "agent_labels" => ["repo=appheat/bible-agents"], "notes" => "Use the VM-local 127.0.0.1:8000 endpoint for JSON API mutations."}, collected_at, design_authority)
  ]),
  "dns.yaml" => document("dns", [
    entity({"name" => "ci.appheat.co", "provider" => "cloudflare", "target" => "tunnel:woodpecker-ci", "purpose" => "Woodpecker web and webhook endpoint"}, collected_at, design_authority),
    entity({"name" => "ci-agent.appheat.co", "provider" => "cloudflare", "target" => "tunnel:woodpecker-ci-agent", "purpose" => "Woodpecker agent endpoint"}, collected_at, design_authority)
  ]),
  "tunnels.yaml" => document("tunnel", [
    entity({"id" => "woodpecker-ci", "provider" => "cloudflare", "hostname" => "ci.appheat.co", "backend" => "http://127.0.0.1:8000"}, collected_at, design_authority),
    entity({"id" => "woodpecker-ci-agent", "provider" => "cloudflare", "hostname" => "ci-agent.appheat.co", "backend" => "unknown"}, collected_at, design_authority)
  ]),
  "databases.yaml" => document("database", [
    entity({"id" => "woodpecker-sqlite", "engine" => "sqlite", "host_ref" => "woodpecker-ci", "app" => "fleet-ci", "env" => "production"}, collected_at, design_authority)
  ]),
  "secrets.yaml" => document("secret_project", [
    entity({"doppler_project" => "fleet-ci", "configs" => ["prd"], "apps" => ["woodpecker"]}, collected_at, design_authority)
  ])
}

FileUtils.mkdir_p(catalog)
stage = Dir.mktmpdir(".estate-seed.", catalog)
begin
  files.each do |name, content|
    File.write(File.join(stage, name), YAML.dump(content))
  end
  FileUtils.mkdir_p(declared)
  existing = Dir.glob(File.join(declared, "**", "*.{yaml,yml}"))
  fail!("declared catalog already contains YAML: #{declared}") unless existing.empty?
  files.keys.sort.each do |name|
    destination = File.join(declared, name)
    fail!("refusing to overwrite declared file: #{destination}") if File.exist?(destination)
    File.rename(File.join(stage, name), destination)
  end
ensure
  FileUtils.remove_entry(stage) if File.exist?(stage)
end

puts "estate seed: wrote #{files.length} declared files to #{declared}"
puts "estate seed: repository entries=#{repositories.length}"
puts "estate seed: complete unknown fields before treating affected consultations as current"
RUBY
