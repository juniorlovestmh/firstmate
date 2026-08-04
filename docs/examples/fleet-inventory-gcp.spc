# Fleet-wide read-only GCP inventory connections.
# Credentials are delivered at runtime and never stored in Git.

connection "gcp_appheat_finops" {
  plugin      = "gcp"
  project     = "appheat-billing-export"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_bible_stg" {
  plugin      = "gcp"
  project     = "bible-agents-stg-15d299"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_legacy_hc_unbilled" {
  plugin      = "gcp"
  project     = "cs-hc-4cb97f9cdd7c417d89bb6e1e"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_legacy_hc_billed" {
  plugin      = "gcp"
  project     = "cs-hc-c097fcc6a9674f5e941dda5d"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_host" {
  plugin      = "gcp"
  project     = "cs-host-e77ac18f45de4a3887284f"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_appheat_experiments" {
  plugin      = "gcp"
  project     = "cs-poc-ihtrpvjwhfhjcgbdxnvrggc"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_autonomy_video" {
  plugin      = "gcp"
  project     = "gen-lang-client-0716059536"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_google_mpf" {
  plugin      = "gcp"
  project     = "google-mpf-74jsxkcveyfq"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_tab_stg" {
  plugin      = "gcp"
  project     = "tab-agent-stg-21d842"
  credentials = "/var/lib/fleet-inventory/gcp-reader.json"
  ignore_error_messages = [
    ".*LOCATION_POLICY_VIOLATED.*",
    ".*SERVICE_DISABLED.*",
    ".*Permission denied on 'locations/.*"
  ]
}

connection "gcp_all" {
  type   = "aggregator"
  plugin = "gcp"
  connections = [
    "gcp_appheat_finops",
    "gcp_bible_stg",
    "gcp_legacy_hc_unbilled",
    "gcp_legacy_hc_billed",
    "gcp_host",
    "gcp_appheat_experiments",
    "gcp_autonomy_video",
    "gcp_google_mpf",
    "gcp_tab_stg"
  ]
}
