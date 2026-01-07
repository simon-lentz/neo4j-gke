# Dev Environment - Neo4j GKE Infrastructure
#
# This environment provisions all platform infrastructure for Neo4j deployment:
# - VPC with Cloud NAT for private GKE nodes
# - GKE Autopilot cluster with Workload Identity
# - Service account for Neo4j backups
# - GCS bucket for backup storage (CMEK encrypted)
# - Secret Manager secrets for credentials

# Read bootstrap state for CMEK key
data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "bootstrap"
  }
}

# VPC Network
module "vpc" {
  source     = "../../modules/vpc"
  project_id = var.project_id
  region     = var.region
  vpc_name   = "neo4j-dev-vpc"

  # IP ranges for GKE
  subnet_ip_range   = var.subnet_ip_range
  pods_ip_range     = var.pods_ip_range
  services_ip_range = var.services_ip_range

  # Enable Cloud NAT for private node egress
  enable_cloud_nat = true
}

# GKE Autopilot Cluster
# Note: enable_private_endpoint defaults to false for dev convenience.
# Production deployments should set enable_private_endpoint = true
# and configure master_authorized_networks for VPN/bastion access.
module "gke" {
  source              = "../../modules/gke"
  project_id          = var.project_id
  region              = var.region
  cluster_name        = "neo4j-dev"
  network_id          = module.vpc.network_id
  subnet_id           = module.vpc.subnet_id
  pods_range_name     = module.vpc.pods_range_name
  services_range_name = module.vpc.services_range_name

  # Dev settings
  deletion_protection = false
  release_channel     = "REGULAR"

  # Maintenance window: weekends
  maintenance_start_time = "2025-01-01T09:00:00Z"
  maintenance_end_time   = "2025-01-01T17:00:00Z"
  maintenance_recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"

  labels = {
    environment = "dev"
    managed_by  = "tofu"
  }
}

# Backup Service Account
module "backup_sa" {
  source     = "../../modules/service_accounts"
  project_id = var.project_id

  service_accounts = {
    "neo4j-backup" = {
      description  = "Neo4j backup service account for dev environment"
      display_name = "Neo4j Backup SA (Dev)"
    }
  }

  # Dev settings - allow destruction for cleanup
  prevent_destroy_service_accounts = false
}

# Grant backup service account permission to use CMEK key
resource "google_kms_crypto_key_iam_member" "backup_sa_kms" {
  crypto_key_id = data.terraform_remote_state.bootstrap.outputs.state.kms_key_name
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${module.backup_sa.service_accounts["neo4j-backup"].email}"
}

# Backup Bucket (CMEK encrypted using bootstrap key)
module "backup_bucket" {
  source          = "../../modules/backup_bucket"
  project_id      = var.project_id
  bucket_name     = "${var.project_id}-neo4j-backups-dev"
  location        = var.region
  backup_sa_email = module.backup_sa.service_accounts["neo4j-backup"].email

  # CMEK encryption using bootstrap key
  kms_key_name = data.terraform_remote_state.bootstrap.outputs.state.kms_key_name

  # Retention settings
  backup_retention_days   = 30
  backup_versions_to_keep = 5

  # WARNING: Dev-only setting - allows bucket deletion even with backup data.
  # Production environments MUST set force_destroy = false to prevent
  # accidental data loss. See backup_bucket module README for guidance.
  force_destroy = true

  labels = {
    environment = "dev"
    purpose     = "neo4j-backup"
    managed_by  = "tofu"
  }

  depends_on = [google_kms_crypto_key_iam_member.backup_sa_kms]
}

# Secrets for Neo4j credentials
module "secrets" {
  source     = "../../modules/secrets"
  project_id = var.project_id

  secrets = {
    "neo4j-admin-password-dev" = {
      description = "Neo4j admin password for dev environment"
      labels = {
        environment = "dev"
        application = "neo4j"
      }
    }
  }

  # No accessors defined here - will be granted via Workload Identity in apps layer
}

# Neo4j Application Deployment
# Only deployed when deploy_neo4j_app = true (after password is set in Secret Manager)
module "neo4j" {
  count  = var.deploy_neo4j_app ? 1 : 0
  source = "../../modules/neo4j_app"

  # Platform inputs
  project_id               = var.project_id
  workload_identity_pool   = module.gke.workload_identity_pool
  backup_gsa_email         = module.backup_sa.service_accounts["neo4j-backup"].email
  backup_gsa_name          = module.backup_sa.service_accounts["neo4j-backup"].name
  backup_bucket_url        = module.backup_bucket.bucket_url
  neo4j_password_secret_id = module.secrets.secret_ids["neo4j-admin-password-dev"]

  # Neo4j configuration
  neo4j_chart_version        = var.neo4j_chart_version
  neo4j_namespace            = var.neo4j_namespace
  neo4j_instance_name        = var.neo4j_instance_name
  neo4j_storage_size         = var.neo4j_storage_size
  enable_neo4j_browser       = var.enable_neo4j_browser
  allowed_ingress_namespaces = var.allowed_ingress_namespaces
  neo4j_password_k8s_secret  = var.neo4j_password_k8s_secret
  enable_external_access     = var.enable_external_access

  depends_on = [module.gke, module.backup_sa, module.backup_bucket, module.secrets]
}
