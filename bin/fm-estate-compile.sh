#!/usr/bin/env bash
# Merge home-private declared and generated estate YAML into agent-facing JSON and Markdown.
# Usage: fm-estate-compile.sh [--catalog PATH] [--now UTC] [--stale-days DAYS]
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
readonly ROOT_DIR
FM_HOME=${FM_HOME:-$ROOT_DIR}
catalog=${FM_ESTATE_CATALOG_DIR:-$FM_HOME/data/estate-catalog}
now=${FM_ESTATE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
stale_days=${FM_ESTATE_STALE_DAYS:-}

usage() {
  cat <<'EOF'
Usage: fm-estate-compile.sh [--catalog PATH] [--now UTC] [--stale-days DAYS]

Merge declared/*.yaml and generated/*.yaml into compiled/estate.json and
compiled/estate.md. Inputs are validated, entity identities must be unique, and
outputs are published atomically in deterministic order.

The default stale threshold is 7 days for hosts and 30 days for every other
kind. --stale-days (or FM_ESTATE_STALE_DAYS) overrides every kind.

Environment:
  FM_HOME                 Firstmate home containing data/estate-catalog
  FM_ESTATE_CATALOG_DIR   Exact catalog directory override
  FM_ESTATE_NOW           UTC evaluation time for reproducible compilation
  FM_ESTATE_STALE_DAYS    Whole-day threshold override for every kind
EOF
}

die() {
  printf 'fm-estate-compile.sh: %s\n' "$*" >&2
  exit 1
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
    --stale-days)
      [ "$#" -ge 2 ] || die "--stale-days requires a whole number"
      stale_days=$2
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

case "$stale_days" in
  ''|*[!0-9]*) [ -z "$stale_days" ] || die "stale days must be a whole number" ;;
esac
command -v ruby >/dev/null 2>&1 || die "ruby is required to parse catalog YAML"

mkdir -p "$catalog/compiled"
ruby - "$catalog" "$now" "$stale_days" <<'RUBY'
require "fileutils"
require "json"
require "pathname"
require "time"
require "yaml"

PROGRAM = "fm-estate-compile.sh"
KINDS = %w[system repository host service ci dns tunnel saas database secret_project].freeze
COMMON_REQUIRED = %w[source collected_at authority].freeze
REQUIRED = {
  "system" => %w[id owner product lifecycle],
  "repository" => %w[id github delivery_mode verify_cmd ci base_branch],
  "host" => %w[id provider ip role ssh_path],
  "service" => %w[id system host url deploy_path],
  "ci" => %w[id product url agent_labels notes],
  "dns" => %w[name provider target purpose],
  "tunnel" => %w[id provider hostname backend],
  "saas" => %w[product account purpose limit_posture],
  "database" => %w[id engine host_ref app env],
  "secret_project" => %w[doppler_project configs apps]
}.freeze
OPTIONAL = Hash.new([].freeze).merge(
  "host" => %w[vmid],
  "service" => %w[health_url],
  "ci" => %w[host]
).freeze
ARRAY_FIELDS = %w[agent_labels configs apps].freeze
ENUMS = {
  "source" => %w[declarative collected],
  "delivery_mode" => %w[no-mistakes direct-PR local-only unknown],
  "ci" => %w[woodpecker none exception unknown],
  "provider" => %w[proxmox exe.dev gcp mac cloudflare unknown],
  "limit_posture" => %w[free paid owned unknown]
}.freeze
RESERVED = %w[age_days entity_ref kind source_file stale stale_after_days stale_reason slice_status unknown_fields].freeze
DEFAULT_STALE_DAYS = Hash.new(30).merge("host" => 7).freeze
UTC_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

def fail!(message)
  warn "#{PROGRAM}: #{message}"
  exit 1
end

def parse_utc(value, label)
  fail!("#{label} must be UTC as YYYY-MM-DDTHH:MM:SSZ") unless value.is_a?(String) && UTC_PATTERN.match?(value)
  Time.iso8601(value).utc
rescue ArgumentError
  fail!("#{label} is not a valid UTC timestamp: #{value.inspect}")
end

def identity_for(kind, entity)
  case kind
  when "dns"
    entity.fetch("name")
  when "saas"
    "#{entity.fetch("product")}@#{entity.fetch("account")}"
  when "secret_project"
    entity.fetch("doppler_project")
  else
    entity.fetch("id")
  end
end

def unknown?(value)
  case value
  when String
    value.strip.empty? || value.strip.casecmp("unknown").zero?
  when Array
    value.empty? || value.any? { |item| unknown?(item) }
  else
    value.nil?
  end
end

def deep_sort(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) { |key, result| result[key] = deep_sort(value[key]) }
  when Array
    value.map { |item| deep_sort(item) }
  else
    value
  end
end

def markdown(value)
  rendered = value.is_a?(Array) || value.is_a?(Hash) ? JSON.generate(value) : value.to_s
  rendered.gsub("|", "\\|").gsub("\n", " ")
end

catalog = Pathname.new(ARGV.fetch(0)).expand_path
now_text = ARGV.fetch(1)
global_days = ARGV.fetch(2)
now = parse_utc(now_text, "evaluation time")
global_threshold = global_days.empty? ? nil : Integer(global_days, 10)

files = %w[declared generated].flat_map do |directory|
  Dir.glob(catalog.join(directory, "**", "*.{yaml,yml}").to_s)
end.sort

entities = []
seen = {}
files.each do |filename|
  path = Pathname.new(filename)
  relative = path.relative_path_from(catalog).to_s
  directory = relative.split("/", 2).first
  expected_source = directory == "declared" ? "declarative" : "collected"
  begin
    document = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
  rescue Psych::Exception, SystemCallError => e
    fail!("#{relative}: YAML parse failed: #{e.message}")
  end
  fail!("#{relative}: document root must be a mapping") unless document.is_a?(Hash)
  document_extra = document.keys - %w[schema_version kind status entities]
  fail!("#{relative}: unsupported document fields: #{document_extra.sort.join(", ")}") unless document_extra.empty?
  fail!("#{relative}: schema_version must be 1") unless document["schema_version"] == 1
  kind = document["kind"]
  fail!("#{relative}: unsupported kind #{kind.inspect}") unless KINDS.include?(kind)
  rows = document["entities"]
  fail!("#{relative}: entities must be a non-empty array") unless rows.is_a?(Array) && !rows.empty?

  status = document.fetch("status", {"state" => "current"})
  fail!("#{relative}: status must be a mapping") unless status.is_a?(Hash)
  status_extra = status.keys - %w[state marked_at reason]
  fail!("#{relative}: unsupported status fields: #{status_extra.sort.join(", ")}") unless status_extra.empty?
  state = status.fetch("state", "current")
  fail!("#{relative}: status.state must be current or stale") unless %w[current stale].include?(state)
  stale_reason = nil
  if state == "stale"
    marked_at = status["marked_at"]
    reason = status["reason"]
    marked_time = parse_utc(marked_at, "#{relative}: status.marked_at")
    fail!("#{relative}: status.marked_at is in the future") if marked_time > now
    fail!("#{relative}: stale status requires a reason") unless reason.is_a?(String) && !reason.strip.empty?
    stale_reason = reason.strip
  end

  rows.each_with_index do |raw, index|
    label = "#{relative}: entities[#{index}]"
    fail!("#{label} must be a mapping") unless raw.is_a?(Hash)
    reserved = raw.keys & RESERVED
    fail!("#{label} uses compiler-reserved fields: #{reserved.sort.join(", ")}") unless reserved.empty?
    required = REQUIRED.fetch(kind) + COMMON_REQUIRED
    allowed = required + OPTIONAL[kind]
    invalid = raw.keys - allowed
    fail!("#{label} fields are not valid for #{kind}: #{invalid.sort.join(", ")}") unless invalid.empty?
    missing = required.reject { |field| raw.key?(field) }
    fail!("#{label} missing required fields: #{missing.join(", ")}") unless missing.empty?
    fail!("#{label} source must be #{expected_source.inspect} for #{directory}/") unless raw["source"] == expected_source

    required.each do |field|
      value = raw[field]
      if ARRAY_FIELDS.include?(field)
        fail!("#{label} #{field} must be a non-empty string array") \
          unless value.is_a?(Array) && !value.empty? && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
      else
        fail!("#{label} #{field} must be a non-empty string") \
          unless value.is_a?(String) && !value.strip.empty?
      end
    end
    if raw.key?("vmid") && raw["vmid"] != "unknown"
      fail!("#{label} vmid must be a positive integer or unknown") unless raw["vmid"].is_a?(Integer) && raw["vmid"].positive?
    end
    ENUMS.each do |field, allowed|
      next unless raw.key?(field)
      fail!("#{label} #{field} must be one of #{allowed.join("|")}") unless allowed.include?(raw[field])
    end

    collected = parse_utc(raw["collected_at"], "#{label} collected_at")
    fail!("#{label} collected_at is in the future") if collected > now
    identity = identity_for(kind, raw)
    ref = "#{kind}:#{identity}"
    fail!("#{label} identity must not be unknown") if unknown?(identity)
    if seen.key?(ref)
      fail!("duplicate entity #{ref} in #{seen.fetch(ref)} and #{relative}")
    end
    seen[ref] = relative

    threshold = global_threshold || DEFAULT_STALE_DAYS[kind]
    age_seconds = now - collected
    age_days = (age_seconds / 86_400).floor
    age_stale = age_seconds > threshold * 86_400
    stale = state == "stale" || age_stale
    reason = stale_reason
    reason ||= "collected_at is older than #{threshold} days" if age_stale
    unknown_fields = required.reject { |field| COMMON_REQUIRED.include?(field) }.select { |field| unknown?(raw[field]) }

    entity = raw.dup
    entity["kind"] = kind
    entity["entity_ref"] = ref
    entity["source_file"] = relative
    entity["slice_status"] = state
    entity["stale_after_days"] = threshold
    entity["age_days"] = age_days
    entity["stale"] = stale
    entity["stale_reason"] = reason if reason
    entity["unknown_fields"] = unknown_fields.sort
    entities << entity
  end
end

entities.sort_by! { |entity| [entity.fetch("kind"), entity.fetch("entity_ref")] }
document = {
  "schema_version" => "estate-catalog.v1",
  "evaluated_at" => now_text,
  "source_files" => files.map { |path| Pathname.new(path).relative_path_from(catalog).to_s },
  "entities" => entities
}

markdown_lines = [
  "# Estate catalog",
  "",
  "Evaluated at `#{now_text}` from #{files.length} source file(s).",
  "",
  "| Kind | Entity | Location | Source | Collected | State | Authority |",
  "| --- | --- | --- | --- | --- | --- | --- |"
]
entities.each do |entity|
  location = entity["url"] || entity["hostname"] || entity["github"] || entity["ip"] || entity["target"] || entity["host_ref"] || "-"
  state = entity["stale"] ? "STALE: #{entity["stale_reason"]}" : "current"
  unless entity["unknown_fields"].empty?
    state = "#{state}; unknown: #{entity["unknown_fields"].join(", ")}"
  end
  markdown_lines << "| #{markdown(entity["kind"])} | #{markdown(entity["entity_ref"])} | #{markdown(location)} | #{markdown(entity["source"])} | #{markdown(entity["collected_at"])} | #{markdown(state)} | #{markdown(entity["authority"])} |"
end
markdown_lines << ""

compiled = catalog.join("compiled")
FileUtils.mkdir_p(compiled)
json_tmp = compiled.join(".estate.json.#{$$}.tmp")
md_tmp = compiled.join(".estate.md.#{$$}.tmp")
begin
  File.write(json_tmp, JSON.pretty_generate(deep_sort(document)) + "\n")
  File.write(md_tmp, markdown_lines.join("\n"))
  File.rename(json_tmp, compiled.join("estate.json"))
  File.rename(md_tmp, compiled.join("estate.md"))
ensure
  File.delete(json_tmp) if File.exist?(json_tmp)
  File.delete(md_tmp) if File.exist?(md_tmp)
end

puts "estate compile: #{entities.length} entities from #{files.length} files"
puts "estate compile: #{compiled.join("estate.json")}"
puts "estate compile: #{compiled.join("estate.md")}"
RUBY
