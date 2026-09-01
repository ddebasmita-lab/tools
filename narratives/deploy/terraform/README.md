# deploy/terraform — one Custom Data Commons instance

This module provisions everything one instance needs. Apply it once per
instance, into its own GCP project.

```
modules/                       the module (used directly as a root config)
  backend.tf                   provider + GCS state backend
  main.tf                      data bucket, Cloud SQL, Cloud Run service, IAM, monitoring
  data_ingest_job.tf           the Cloud Run job that loads custom CSVs
  service_account.tf           the runtime service account and its role bindings
  variables.tf                 every input, with what it does
  terraform.tfvars.sample      copy this for an instance in an existing project
new-instance.tfvars.sample     copy this for a brand-new project — start here
```

## What it creates

A two-container Cloud Run v2 service — the `services` container (nginx + the
Flask web app + Mixer + the MCP server + the NL server) and the `agent` sidecar
— plus a Cloud SQL MySQL instance, a per-instance data bucket, a data-ingest
Cloud Run job, a runtime service account with its bindings, and uptime checks
with optional alerting.

## Before the first apply

Three things must already exist; Terraform reads them and does not create them.

1. **A state bucket**, `gs://<project_id>-tfstate`, with versioning on.
2. **The four secrets**, each holding an enabled version — `dc-api-key`,
   `maps-api-key`, `db-pass`, `gemini-api-keys`. Secret *rotation* is an
   operational task, so the secrets are deliberately outside Terraform; a
   rotation should not produce a state diff.
3. **An Artifact Registry repository** holding the two images, and the images
   pushed to it.

```sh
cd modules
terraform init \
  -backend-config="bucket=<project_id>-tfstate" \
  -backend-config="prefix=cdc/<instance>"
terraform apply -var-file=../<instance>.tfvars
```

Then run the ingest job once, so the NL embeddings and the custom catalog exist:

```sh
gcloud run jobs execute <instance>-data-ingest --region <region> --wait
```

## Three things worth knowing before you apply

**Nobody can reach the UI until you say who may.** `invoker_members` is empty by
default, which grants `roles/run.invoker` to no one — the service deploys and
only project-level Cloud Run admins can invoke it. Set it deliberately:
`["allUsers"]` for a public instance, or a list of `user:` / `group:` members.
No identity is baked into this module.

**Leave `output_dir` and `input_dir` empty.** The module then derives
`gs://<data bucket>/output` and `/input`, and both the ingest job and the
services container read that one value — so they cannot disagree. If you
override them with a bare bucket path, the job writes to one prefix and the
service reads another. Nothing errors. The only symptom is a log line that looks
harmless:

```
No object found from <bucket>/datacommons/nl/custom_dc_topic_cache.json
```

and custom variables that are silently missing from search even though the
ingest indexed them correctly. An override must be the full path, including the
subdirectory.

**Decide up front whether the instance is disposable.** Two flags govern
teardown, and both default to the safe setting:

| Variable | Default | Set this way to allow teardown |
|---|---|---|
| `deletion_protection` | `true` — protects Cloud SQL, the ingest job and the service | `false` |
| `force_destroy` | `false` — refuses to delete a data bucket holding objects | `true` |

`new-instance.tfvars.sample` ships with `false` / `true`, because a fresh
instance is usually a trial. Flip both before the instance holds anything you
cannot lose.

Getting this wrong is more annoying than it sounds. `terraform destroy` fails
partway, and the `apply` you then need in order to change the flags *re-creates*
the resources it already deleted before you can destroy again. Changing the flag
on the resource with `gcloud` is not enough — the config still declares the old
value, so the next apply restores it.

## Conventions

- **One instance, one project, one state prefix.** State lives at
  `gs://<project_id>-tfstate/cdc/<instance>/`. There is no shared control plane.
- **Resources are named from `var.instance`** — the service is
  `<instance>-datacommons`, the database `dc-<instance>-mysql`, the data bucket
  `<instance>-data-<project_id>`.
- **`FORCE_RESTART` is set out of band**, so container `env` blocks are in
  `lifecycle.ignore_changes`. Terraform will not fight your manual restarts.
- **Real `.tfvars` files are git-ignored**; only the `.sample` files ship. They
  carry project IDs and image tags, which are per-instance.
