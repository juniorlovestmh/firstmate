#!/usr/bin/env bash
# Consult compiled estate truth before infra-shaped planning or dispatch.
# Usage: fm-estate-consult.sh [--catalog PATH] [--now UTC] [--max-age-days DAYS] <topic-or-kind...>
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
readonly ROOT_DIR
FM_HOME=${FM_HOME:-$ROOT_DIR}
catalog=${FM_ESTATE_CATALOG_DIR:-$FM_HOME/data/estate-catalog}
now=${FM_ESTATE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
max_age_days=

usage() {
  cat <<'EOF'
Usage: fm-estate-consult.sh [--catalog PATH] [--now UTC] [--max-age-days DAYS] <topic-or-kind...>

Read compiled/estate.json and print a paste-ready "Estate already exists" block.
Infra topics resolve to their required estate kinds; the command exits 1 when
matching required truth is missing, stale, or incomplete.

Use kind:<name> to consult exactly one kind without topic dependencies.
Compute hosts default to the catalog's seven-day threshold.

Environment:
  FM_HOME                 Firstmate home containing data/estate-catalog
  FM_ESTATE_CATALOG_DIR   Exact catalog directory override
  FM_ESTATE_NOW           UTC evaluation time for reproducible consultation
EOF
}

die() {
  printf 'fm-estate-consult.sh: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog)
      [ "$#" -ge 2 ] || die "--catalog requires a path"
      catalog=$2
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || die "--now requires a UTC timestamp"
      now=$2
      shift 2
      ;;
    --max-age-days)
      [ "$#" -ge 2 ] || die "--max-age-days requires a whole number"
      max_age_days=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unexpected option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -gt 0 ] || die "at least one topic or kind is required"
case "$max_age_days" in
  ''|*[!0-9]*) [ -z "$max_age_days" ] || die "max age days must be a whole number" ;;
esac
command -v ruby >/dev/null 2>&1 || die "ruby is required to read compiled estate truth"
compiled="$catalog/compiled/estate.json"
[ -r "$compiled" ] || die "compiled estate is missing: $compiled (run bin/fm-estate-compile.sh)"

ruby - "$compiled" "$now" "$max_age_days" "$@" <<'RUBY'
require "json"
require "time"

PROGRAM = "fm-estate-consult.sh"
KINDS = %w[system repository host service ci dns tunnel saas database secret_project].freeze
UTC_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
KEYWORDS = {
  "system" => [%w[system], %w[system]],
  "product" => [%w[system], %w[system]],
  "repository" => [%w[repository], %w[repository]],
  "repo" => [%w[repository], %w[repository]],
  "host" => [%w[host], %w[host]],
  "vm" => [%w[host], %w[host]],
  "compute" => [%w[host], %w[host]],
  "proxmox" => [%w[host], %w[host]],
  "exe.dev" => [%w[host], %w[host]],
  "runner" => [%w[host], %w[host]],
  "service" => [%w[service host], %w[service]],
  "deploy" => [%w[service host], %w[service]],
  "topology" => [%w[service host], %w[service]],
  "ci" => [%w[ci host], %w[ci]],
  "pipeline" => [%w[ci host], %w[ci]],
  "woodpecker" => [%w[ci host], %w[ci]],
  "dns" => [%w[dns], %w[dns]],
  "domain" => [%w[dns], %w[dns]],
  "tunnel" => [%w[tunnel], %w[tunnel]],
  "cloudflare" => [%w[tunnel dns], %w[tunnel]],
  "saas" => [%w[saas], %w[saas]],
  "provision" => [%w[saas], %w[saas]],
  "provisioning" => [%w[saas], %w[saas]],
  "database" => [%w[database host], %w[database]],
  "db" => [%w[database host], %w[database]],
  "secret_project" => [%w[secret_project], %w[secret_project]],
  "secret" => [%w[secret_project], %w[secret_project]],
  "doppler" => [%w[secret_project], %w[secret_project]]
}.freeze

def fatal(message)
  warn "#{PROGRAM}: #{message}"
  exit 2
end

def parse_utc(value, label)
  fatal("#{label} must be UTC as YYYY-MM-DDTHH:MM:SSZ") unless value.is_a?(String) && UTC_PATTERN.match?(value)
  Time.iso8601(value).utc
rescue ArgumentError
  fatal("#{label} is not a valid UTC timestamp: #{value.inspect}")
end

def add_unique(array, values)
  values.each { |value| array << value unless array.include?(value) }
end

def ref_for(kind, id)
  "#{kind}:#{id}"
end

def detail_for(entity)
  location = entity["url"] || entity["hostname"] || entity["github"] || entity["ip"] || entity["target"] || entity["host_ref"] || "no location"
  "#{location} (authority: #{entity.fetch("authority")}; collected: #{entity.fetch("collected_at")})"
end

path = ARGV.fetch(0)
now = parse_utc(ARGV.fetch(1), "evaluation time")
max_age = ARGV.fetch(2)
max_age = max_age.empty? ? nil : Integer(max_age, 10)
topics = ARGV.drop(3)

begin
  catalog = JSON.parse(File.read(path))
rescue JSON::ParserError, SystemCallError => e
  fatal("compiled estate is unreadable: #{e.message}")
end
fatal("compiled estate schema_version must be estate-catalog.v1") unless catalog["schema_version"] == "estate-catalog.v1"
entities = catalog["entities"]
fatal("compiled estate entities must be an array") unless entities.is_a?(Array)

tokens = topics.flat_map { |topic| topic.downcase.scan(/[a-z0-9_.:-]+/) }.uniq
required = []
direct = []
unknown = []
tokens.each do |token|
  if token.start_with?("kind:")
    kind = token.delete_prefix("kind:")
    if KINDS.include?(kind)
      add_unique(required, [kind])
      add_unique(direct, [kind])
    else
      unknown << "unsupported estate kind: #{kind}"
    end
    next
  end
  mapping = KEYWORDS[token]
  next unless mapping
  add_unique(required, mapping[0])
  add_unique(direct, mapping[1])
end
unknown << "no required kind recognized for topic: #{topics.join(" ")}" if required.empty?

selected = entities.select do |entity|
  direct.include?(entity["kind"]) || tokens.any? { |token| JSON.generate(entity).downcase.include?(token) }
end

by_ref = entities.each_with_object({}) { |entity, result| result[entity["entity_ref"]] = entity }
loop do
  before = selected.length
  selected.dup.each do |entity|
    refs = []
    refs << ref_for("host", entity["host"]) if entity["host"].is_a?(String)
    refs << ref_for("host", entity["host_ref"]) if entity["host_ref"].is_a?(String)
    refs << ref_for("system", entity["system"]) if entity["system"].is_a?(String)
    target = entity["target"]
    refs << target if target.is_a?(String) && target.match?(/\A(?:#{KINDS.join("|")}):/)
    refs.each do |ref|
      linked = by_ref[ref]
      selected << linked if linked && !selected.include?(linked)
    end
  end
  break if selected.length == before
end
selected.sort_by! { |entity| entity.fetch("entity_ref") }

required.each do |kind|
  matching = selected.select { |entity| entity["kind"] == kind }
  if matching.empty?
    if entities.none? { |entity| entity["kind"] == kind }
      unknown << "missing required kind: #{kind}"
    else
      unknown << "no matching entity for required kind: #{kind}"
    end
    next
  end
  matching.each do |entity|
    threshold = max_age || entity.fetch("stale_after_days")
    collected = parse_utc(entity["collected_at"], "#{entity["entity_ref"]} collected_at")
    explicit_stale = entity["slice_status"] == "stale"
    age_stale = now - collected > threshold * 86_400
    if explicit_stale || age_stale
      reason = explicit_stale ? entity["stale_reason"] : "collected_at is older than #{threshold} days"
      unknown << "stale required entity: #{entity["entity_ref"]} (#{reason})"
    end
    fields = entity["unknown_fields"]
    if fields.is_a?(Array) && !fields.empty?
      unknown << "unknown required fields: #{entity["entity_ref"]} (#{fields.join(", ")})"
    end
  end
end
unknown << "no matching estate entities for topic: #{topics.join(" ")}" if selected.empty?

puts "Estate already exists"
if selected.empty?
  puts "- none found"
else
  selected.each do |entity|
    puts "- [#{entity.fetch("kind")}] #{entity.fetch("entity_ref").split(":", 2).last}: #{detail_for(entity)}"
  end
end
puts "Unknown surfaces"
if unknown.empty?
  puts "- none"
else
  unknown.uniq.sort.each { |line| puts "- #{line}" }
end

exit(unknown.empty? ? 0 : 1)
RUBY
