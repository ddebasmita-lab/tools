# Runtime service account for the Cloud Run service.
# Cloud Run v2 multi-container shares one SA across all containers in a service —
# there is no per-container SA option. We grant the union of what services and
# agent need, with the narrowest viable set.

resource "google_service_account" "datacommons" {
  account_id   = "${var.instance}-runtime"
  display_name = "Data Commons runtime SA (${var.instance})"
  description  = "Workload Identity SA for the Cloud Run multi-container service; reads Secret Manager, branding bucket, data bucket, NL model bucket."
}

# 1. Secret Manager read — Gemini keys, DB password, DC + Maps API keys.
resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.datacommons.email}"
}

# 2. Cloud SQL client — runtime DB connection.
resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.datacommons.email}"
}

# 3. Cloud Storage object viewer — branding bucket + the public NL models bucket.
#    Scoped to the branding bucket below; the public bucket reads work via
#    allUsers but we list this role explicitly so VPC-SC rollouts don't break us.
resource "google_storage_bucket_iam_member" "config_reader" {
  bucket = data.google_storage_bucket.config.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.datacommons.email}"
}

# 4. Cloud Storage object admin on the data bucket — the ingest job WRITES
#    outputs (embeddings, custom_catalog.yaml) and a gcsfs placeholder blob in
#    input/, and the services container reads them back. objectViewer is
#    insufficient: the ingest fails with storage.objects.create denied.
resource "google_storage_bucket_iam_member" "data_reader" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.datacommons.email}"
}

# Additional shared buckets, for instances that read data from a bucket this
# module did not create.
resource "google_storage_bucket_iam_member" "extra_data_readers" {
  for_each = toset(var.extra_data_buckets)
  bucket   = each.value
  role     = "roles/storage.objectViewer"
  member   = "serviceAccount:${google_service_account.datacommons.email}"
}

# 5. Logging writer — for structured logs to Cloud Logging.
resource "google_project_iam_member" "log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.datacommons.email}"
}

# 6. Metric writer — for runtime metrics.
resource "google_project_iam_member" "metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.datacommons.email}"
}

# 7. Cloud Trace agent — for tracing.
resource "google_project_iam_member" "trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.datacommons.email}"
}
