terraform {
  backend "gcs" {}
}

variable "secrets_dir" {}
variable "charts_dir" {}
variable "cloud_sdk_repository" {}
variable "cloud_sdk_tag" {}

# `destination_bucket` - The destination GCS bucket, i.e "gpii-backup-external-prd".
variable "destination_bucket" {}

variable "project_id" {}

# `replica_count` - the number of CouchDB replicas that the cluster has. This is important for copying all the snapshots of the cluster at the same time.
variable "replica_count" {}

# `schedule` - Follows the same format as a Cron Job. i.e: `*/10 * * * *` to execute the task every 10 minutes.
variable "schedule" {}

variable "serviceaccount_key" {}

# Region where the cluster is
variable "infra_region" {}

# Zone inside the region where the cluster is
variable "zone" {
  default = "a"
}

# Network to attach the VM created by CloudBuild
variable "vm_network" {
  default = "network"
}

variable "vm_subnetwork" {
  default = "nodes"
}

provider "google" {
  project     = "${var.project_id}"
  credentials = "${var.serviceaccount_key}"
}

data "google_project" "project" {
  project_id = "${var.project_id}"
}

data "template_file" "backup-exporter" {
  template = "${file("values.yaml")}"

  vars {
    cloud_sdk_repository      = "${var.cloud_sdk_repository}"
    cloud_sdk_tag             = "${var.cloud_sdk_tag}"
    service_account_name      = "${data.google_service_account.gke_cluster_pod_backup_exporter.email}"
    destination_bucket        = "${var.destination_bucket}"
    local_intermediate_bucket = "${google_storage_bucket.backup_daisy_bkt.name}"
    replica_count             = "${var.replica_count}"
    log_bucket                = "${google_storage_bucket.backup_daisy_bkt.name}"
    schedule                  = "${var.schedule}"
    infra_region              = "${var.infra_region}"
    vm_network                = "${var.vm_network}"
    vm_subnetwork             = "${var.vm_subnetwork}"
    zone                      = "${var.zone}"
  }
}

module "backup-exporter" {
  source           = "/exekube-modules/helm-release"
  tiller_namespace = "kube-system"
  client_auth      = "${var.secrets_dir}/kube-system/helm-tls"

  release_name            = "backup-exporter"
  release_namespace       = "backup-exporter"
  release_values          = ""
  release_values_rendered = "${data.template_file.backup-exporter.rendered}"

  chart_name = "${var.charts_dir}/backup-exporter"
}

resource "google_storage_bucket" "backup_daisy_bkt" {
  project = "${data.google_project.project.project_id}"

  # The Daisy bucket can use a different name depending on the zone where the
  # Cloudbuild runs. By default it uses [project_name]-daisy-bkt but if the zone
  # is set to us-* the name of the bucket will end with -us
  name = "${data.google_project.project.name}-daisy-bkt-us"

  force_destroy = true
}

data "terraform_remote_state" "alert_notification_channel" {
  backend = "gcs"

  config {
    credentials    = "${var.serviceaccount_key}"
    bucket         = "${var.project_id}-tfstate"
    prefix         = "${var.env}/k8s/stackdriver/monitoring"
    encryption_key = "${var.key_tfstate_encryption_key}"
  }
}
