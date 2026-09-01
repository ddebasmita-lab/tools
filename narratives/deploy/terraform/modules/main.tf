# Core resources for one Custom Data Commons instance. Each instance is a
# fully independent deployment in its own GCP project — no shared resources
# across instances.
#
#   - Cloud Run v2 service with two containers (services ingress + agent sidecar)
#   - Cloud SQL HA (MySQL) for the upstream Mixer
#   - Per-instance GCS data bucket
#   - Per-instance Secret Manager entries (DC_API_KEY, MAPS_API_KEY, DB_PASS, GEMINI_API_KEYS)
#   - Uptime checks + alert policies
#
# The per-instance config bucket (gs://<project>-config/) and the Artifact
# Registry repo are created out-of-band by DEPLOY.md Phase 1 and Phase 4
# before terraform apply. The tfvars provide the image paths, the config
# bucket name, and the brand_config_url only.

locals {
  service_name = "${var.instance}-datacommons"
  # Data bucket naming convention: <instance>-data-<project>.
  data_bucket_name = "${var.instance}-data-${var.project_id}"
  # Cloud SQL connection name + DB user — switch to an override when sharing
  # a populated instance during the POC; otherwise use the module-created one.
  cloudsql_connection_name = var.cloudsql_instance_override != "" ? var.cloudsql_instance_override : google_sql_database_instance.dc.connection_name
  db_user                  = var.db_user_override != "" ? var.db_user_override : google_sql_user.dc.name
  output_dir               = var.output_dir != "" ? var.output_dir : "gs://${google_storage_bucket.data.name}/output"
  input_dir                = var.input_dir != "" ? var.input_dir : "gs://${google_storage_bucket.data.name}/input"
}

# ---------------------------------------------------------------------------
# Per-instance data bucket (created here)
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "data" {
  name                        = local.data_bucket_name
  location                    = var.region
  force_destroy               = var.force_destroy
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }
}

# Reference to the per-instance config bucket (NOT managed here — created out-of-band
# by DEPLOY.md Phase 4 before terraform apply). One bucket per instance.
data "google_storage_bucket" "config" {
  name = var.config_bucket
}

# ---------------------------------------------------------------------------
# Cloud SQL
# ---------------------------------------------------------------------------

resource "google_sql_database_instance" "dc" {
  name                = "dc-${var.instance}-mysql"
  database_version    = "MYSQL_8_0"
  region              = var.region
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.cloudsql_tier
    availability_type = var.cloudsql_availability_type
    disk_autoresize   = true
    disk_size         = 20
    disk_type         = "PD_SSD"

    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled = true
      # Authorised networks left empty — Cloud Run connects via the
      # CloudSQL Auth Proxy / direct VPC egress, not via public IP allowlist.
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = false
    }
  }
}

resource "google_sql_database" "dc" {
  name     = "datacommons"
  instance = google_sql_database_instance.dc.name
}

resource "google_sql_user" "dc" {
  name     = "dc_runtime"
  instance = google_sql_database_instance.dc.name
  password = data.google_secret_manager_secret_version.db_pass.secret_data
}

# ---------------------------------------------------------------------------
# Secrets
#   - DC_API_KEY is project-wide (shared across instances) — referenced via data source.
#   - MAPS_API_KEY / DB_PASS / GEMINI_API_KEYS are per-instance; each is
#     named by its own variable (var.maps_api_key_secret_id,
#     var.db_pass_secret_id, var.gemini_api_keys_secret_id).
#   - All secrets must have an enabled version BEFORE `terraform apply`.
# ---------------------------------------------------------------------------

data "google_secret_manager_secret" "dc_api_key" {
  secret_id = var.dc_api_key_secret_id
}

# Per-instance secrets are created out-of-band before first apply.
# Rationale: secret rotation is an operational task; we don't want a tfstate
# diff every time a key is rotated.
data "google_secret_manager_secret" "maps_api_key" {
  secret_id = var.maps_api_key_secret_id
}

data "google_secret_manager_secret" "db_pass" {
  secret_id = var.db_pass_secret_id
}

data "google_secret_manager_secret" "gemini_api_keys" {
  secret_id = var.gemini_api_keys_secret_id
}

# Read DB_PASS for the SQL user resource above. The version must exist before
# `terraform apply`.
data "google_secret_manager_secret_version" "db_pass" {
  secret  = data.google_secret_manager_secret.db_pass.secret_id
  version = "latest"
}

# ---------------------------------------------------------------------------
# Cloud Run v2 multi-container service
# ---------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "dc_web_service" {
  name     = local.service_name
  location = var.region
  # Wired to the same flag as Cloud SQL and the ingest job, so one setting
  # governs whether the whole instance can be torn down.
  deletion_protection = var.deletion_protection

  template {
    service_account = google_service_account.datacommons.email
    timeout         = "600s"

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # 1. Services container — ingress. nginx + Flask + Mixer + MCP + NL server.
    containers {
      name  = "services"
      image = var.dc_web_service_image

      ports {
        container_port = 8080
      }

      resources {
        cpu_idle = false
        limits = {
          cpu    = var.services_cpu
          memory = var.services_memory
        }
        startup_cpu_boost = true
      }

      env {
        name  = "FLASK_ENV"
        value = "custom"
      }
      env {
        name  = "ENABLE_MODEL"
        value = "true"
      }
      env {
        name  = "ENABLE_MCP"
        value = "true"
      }
      env {
        name  = "USE_CLOUDSQL"
        value = "true"
      }
      env {
        name  = "USE_SQLITE"
        value = "false"
      }
      env {
        name  = "DC_API_ROOT"
        value = "https://api.datacommons.org"
      }
      env {
        name  = "DC_SEARCH_SCOPE"
        value = "base_and_custom"
      }
      env {
        name  = "DISABLE_GOOGLE_MAPS"
        value = "false"
      }
      env {
        name  = "CLOUDSQL_INSTANCE"
        value = local.cloudsql_connection_name
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.dc.name
      }
      env {
        name  = "DB_USER"
        value = local.db_user
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOOGLE_CLOUD_REGION"
        value = var.region
      }
      env {
        name  = "BRAND_CONFIG_URL"
        value = var.brand_config_url
      }
      env {
        name  = "INPUT_DIR"
        value = local.input_dir
      }
      env {
        name  = "OUTPUT_DIR"
        value = local.output_dir
      }
      env {
        name = "DC_API_KEY"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.dc_api_key.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "MAPS_API_KEY"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.maps_api_key.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "DB_PASS"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.db_pass.secret_id
            version = "latest"
          }
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        initial_delay_seconds = 30
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 30
      }
    }

    # 2. Agent sidecar — no ports block, so it's not the ingress; reachable
    #    only via shared localhost from the services container.
    containers {
      name  = "agent"
      image = var.dc_agent_image

      resources {
        limits = {
          cpu    = var.agent_cpu
          memory = var.agent_memory
        }
      }

      env {
        name  = "PROXY_PORT"
        value = "5001"
      }
      env {
        name  = "MCP_PORT"
        value = "8082"
      }
      env {
        name  = "TIMEZONE"
        value = var.timezone
      }
      env {
        name  = "ALLOWED_ORIGIN"
        value = var.allowed_origin
      }
      env {
        name  = "AGENT_CONFIG_MODE"
        value = var.agent_config_mode
      }
      env {
        name  = "BRAND_CONFIG_URL"
        value = var.brand_config_url
      }
      env {
        name  = "CONFIG_URL"
        value = "${var.brand_config_url}/agent-config.json"
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GEMINI_API_KEYS_SECRET"
        value = data.google_secret_manager_secret.gemini_api_keys.secret_id
      }
      # FORCE_RESTART is bumped by `gcloud run services update --update-env-vars`
      # to roll a new revision after a Secret Manager rotation or branding
      # bucket update. Terraform tolerates drift on this env so the field can be
      # changed out-of-band without a tfstate replan.
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloudsql_connection_name]
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [
      # FORCE_RESTART is set out-of-band; don't fight tfstate over it.
      template[0].containers[0].env,
      template[0].containers[1].env,
    ]
  }
}

# Who may reach the UI. Driven entirely by var.invoker_members so that no
# identity is baked into the module — an empty list grants nobody and leaves
# the service reachable only by project-level Cloud Run admins.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = toset(var.invoker_members)

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.dc_web_service.name
  role     = "roles/run.invoker"
  member   = each.value
}


# ---------------------------------------------------------------------------
# Artifact Registry — referenced, not created (shared across instances).
# Create out-of-band in Stage 1 with:
#   gcloud artifacts repositories create dc-images \
#     --repository-format=docker --location=<region>
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Uptime checks + alert policies
# ---------------------------------------------------------------------------

resource "google_monitoring_uptime_check_config" "homepage" {
  display_name = "${local.service_name}-homepage"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path           = "/healthz"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"
    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      # The Cloud Run URL is computed at runtime; the uptime check is wired
      # via host below.
      host = trimprefix(google_cloud_run_v2_service.dc_web_service.uri, "https://")
    }
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  count        = length(var.alert_notification_channels) > 0 ? 1 : 0
  display_name = "${local.service_name} uptime check failing"
  combiner     = "OR"

  conditions {
    display_name = "Uptime check failed"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.labels.check_id=\"${google_monitoring_uptime_check_config.homepage.uptime_check_id}\""
      duration        = "60s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }

  notification_channels = var.alert_notification_channels
}

# ---------------------------------------------------------------------------
# Identity-Aware Proxy (IAP) Access Control
# ---------------------------------------------------------------------------

# Authorized accessors for the IAP-protected Cloud Run service
resource "google_iap_web_iam_member" "iap_accessors" {
  for_each = toset(var.iap_authorized_members)

  project = var.project_id
  role    = "roles/iap.httpsResourceAccessor"
  member  = each.value
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "service_url" {
  description = "Cloud Run service URL — share this with the demo team / state outreach."
  value       = google_cloud_run_v2_service.dc_web_service.uri
}

output "cloudsql_connection_name" {
  description = "Connection name for the Cloud SQL instance, used by env CLOUDSQL_INSTANCE."
  value       = google_sql_database_instance.dc.connection_name
}

output "config_bucket" {
  description = "Per-instance GCS config bucket (object-versioned, public read for branding.json access)."
  value       = data.google_storage_bucket.config.name
}

output "data_bucket" {
  description = "GCS data bucket for the upstream ingest job."
  value       = google_storage_bucket.data.name
}

output "runtime_service_account" {
  description = "Email of the runtime SA. Reference in any per-instance IAM grants."
  value       = google_service_account.datacommons.email
}
