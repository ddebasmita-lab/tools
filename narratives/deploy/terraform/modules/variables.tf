# Inputs for the Custom Data Commons multi-container Cloud Run module.
# Per-instance tfvars override these in deploy/terraform-custom-datacommons/<instance>.tfvars.

variable "project_id" {
  description = "GCP project ID hosting the Cloud Run service and Cloud SQL. Each state instance can share a platform project or get its own; the module is project-agnostic."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Cloud SQL, Artifact Registry, GCS, Secret Manager replication. Pick one close to the user base."
  type        = string
  default     = "us-central1"
}

variable "instance" {
  description = "Short instance namespace, e.g. \"demo\", \"statewide\". Used to name resources and (with var.region) the Cloud Run service URL."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.instance))
    error_message = "instance must be a DNS-safe lowercase label (RFC 1123)."
  }
}

variable "dc_web_service_image" {
  description = "Artifact Registry path to the services overlay image (image/Dockerfile output). Tag is the short git SHA from build.sh."
  type        = string
}

variable "dc_agent_image" {
  description = "Artifact Registry path to the sidecar agent image (agent/Dockerfile output)."
  type        = string
}

variable "brand_config_url" {
  description = "HTTPS URL (no trailing slash) where this instance's config bucket contents are served, e.g. https://storage.googleapis.com/<project>-config. The React UI fetches branding.json from this base; the agent fetches agent-config.json. Points at the bucket ROOT — no <instance>/v1/ subpath."
  type        = string
}

variable "agent_config_mode" {
  description = "Whether the agent serves a writable config panel (dev) or hides it (prod). Identical schema in both modes."
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "prod"], var.agent_config_mode)
    error_message = "agent_config_mode must be \"dev\" or \"prod\"."
  }
}

variable "timezone" {
  description = "IANA timezone the agent uses when rendering {{CURRENT_DATETIME}}, e.g. \"America/Los_Angeles\". Defaults to UTC."
  type        = string
  default     = "UTC"
}

variable "cloudsql_tier" {
  description = "Cloud SQL machine tier. db-g1-small is a reasonable POC default; bump to db-custom-2-7680 for production load."
  type        = string
  default     = "db-g1-small"
}

variable "cloudsql_availability_type" {
  description = "Cloud SQL availability mode. REGIONAL is HA (multi-zone); ZONAL is single-zone (cheaper, no failover)."
  type        = string
  default     = "REGIONAL"
  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.cloudsql_availability_type)
    error_message = "cloudsql_availability_type must be REGIONAL or ZONAL."
  }
}

variable "min_instances" {
  description = "Cloud Run min instances. min=1 eliminates cold starts; min=0 saves cost when idle."
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Cloud Run max instances. Cap on autoscale headroom."
  type        = number
  default     = 10
}

variable "services_cpu" {
  description = "vCPU for the services container."
  type        = string
  default     = "2"
}

variable "services_memory" {
  description = "Memory for the services container."
  type        = string
  default     = "2Gi"
}

variable "agent_cpu" {
  description = "vCPU for the agent sidecar container."
  type        = string
  default     = "1"
}

variable "agent_memory" {
  description = "Memory for the agent sidecar container."
  type        = string
  default     = "512Mi"
}

variable "allowed_origin" {
  description = "Comma-separated CORS origins for the agent. In single-URL Cloud Run deployments, set this to the Cloud Run service URL (or custom domain). Default \"*\" is fine for dev but should be tightened in prod."
  type        = string
  default     = "*"
}

variable "alert_notification_channels" {
  description = "Cloud Monitoring notification channel IDs for uptime / error-rate alerts. Leave empty to skip alert creation."
  type        = list(string)
  default     = []
}

variable "config_bucket" {
  description = "Name (not URL) of the per-instance config bucket. Holds branding.json, agent-config.json, prompts/, skills/, assets/ at the bucket root. One bucket per instance — not shared across states. Created out-of-band by DEPLOY.md Phase 4."
  type        = string
}

# Explicit per-secret IDs. All four must already exist (created out-of-band)
# with at least one enabled version. The module reads via data sources;
# rotations are an operational task, not a tfstate diff.

variable "dc_api_key_secret_id" {
  description = "Secret Manager ID for DC_API_KEY (Data Commons API)."
  type        = string
}

variable "maps_api_key_secret_id" {
  description = "Secret Manager ID for MAPS_API_KEY (Google Maps)."
  type        = string
}

variable "db_pass_secret_id" {
  description = "Secret Manager ID for the Cloud SQL user password."
  type        = string
}

variable "gemini_api_keys_secret_id" {
  description = "Secret Manager ID for GEMINI_API_KEYS (JSON array of keys for rotation)."
  type        = string
}

# Data-layer overrides — for sharing an existing populated Cloud SQL across
# instances during the POC. Leave empty to use the SQL instance created by
# this module.

variable "cloudsql_instance_override" {
  description = "If set, Cloud Run uses this Cloud SQL connection name instead of the module-created instance. Format: project:region:instance."
  type        = string
  default     = ""
}

variable "db_user_override" {
  description = "If set, Cloud Run uses this DB_USER instead of dc_runtime (created by the module)."
  type        = string
  default     = ""
}

variable "output_dir" {
  description = <<-EOT
    Where the ingest job writes the NL embeddings and custom catalog, and where
    the services container reads them from. Both consumers use this one value,
    so they cannot disagree.

    Leave empty (recommended) and the module uses gs://<data bucket>/output. An
    override must be the FULL path including the subdirectory — passing the bare
    bucket makes the service read a prefix the job never wrote to, and custom
    variables then go silently missing from search.
  EOT
  type        = string
  default     = ""
}

variable "input_dir" {
  description = <<-EOT
    Where the ingest job reads source CSVs from. Leave empty (recommended) and
    the module uses gs://<data bucket>/input. As with output_dir, an override
    must be the FULL path including the subdirectory.
  EOT
  type        = string
  default     = ""
}

variable "extra_data_buckets" {
  description = "Additional GCS bucket names the runtime SA should be granted objectViewer on, for instances reading a bucket this module did not create."
  type        = list(string)
  default     = []
}

variable "invoker_members" {
  description = <<-EOT
    IAM members granted roles/run.invoker — who may reach the UI. Each entry is
    a fully-qualified member: "user:someone@example.com", "group:team@example.com",
    "serviceAccount:...", or "allUsers" to make the instance public.

    Defaults to empty, which grants nobody: the service deploys but only
    project-level Cloud Run admins can invoke it. Set this deliberately.
  EOT
  type        = list(string)
  default     = []
}

variable "iap_authorized_members" {
  description = "List of groups or users (prefixed with group: or user:) authorized to access the IAP-protected Cloud Run service."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Deletion protection on the Cloud SQL instance and the ingest job. Defaults to true; a throwaway or POC instance must set false, or terraform destroy fails partway and the recovery apply re-creates what it already deleted."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Whether terraform destroy may delete the data bucket while it still holds objects. Defaults to false; the ingest job fills the bucket, so a teardown-able instance must set true or empty the bucket by hand first."
  type        = bool
  default     = false
}
