# Neo4j App Module Variables
#
# This module accepts direct inputs from the calling environment (no terraform_remote_state).
# All platform layer values are passed as variables.

# Platform layer inputs
variable "project_id" {
  type        = string
  description = "GCP project ID."
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.project_id))
    error_message = "project_id must match GCP constraints."
  }
}

variable "workload_identity_pool" {
  type        = string
  description = "Workload Identity pool (format: PROJECT_ID.svc.id.goog)."
}

variable "backup_gsa_email" {
  type        = string
  description = "Email of the GCP service account for backups."
}

variable "backup_gsa_name" {
  type        = string
  description = "Full resource name of the backup service account."
}

variable "backup_bucket_url" {
  type        = string
  description = "GCS bucket URL for Neo4j backups."
}

variable "neo4j_password_secret_id" {
  type        = string
  description = "Secret Manager secret ID for Neo4j password. Used when neo4j_password_k8s_secret is null."
  default     = null
}

# Neo4j configuration
variable "environment" {
  type        = string
  description = "Environment name (e.g., dev, staging, prod)."
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod", "test"], var.environment)
    error_message = "environment must be one of: dev, staging, prod, test."
  }
}

variable "neo4j_chart_version" {
  type        = string
  description = "Version of the Neo4j Helm chart to deploy. Requires 2025.10+ for native Vector type."
  default     = "2025.10.1"
}

variable "neo4j_namespace" {
  type        = string
  description = "Kubernetes namespace for Neo4j deployment."
  default     = "neo4j"
}

variable "neo4j_instance_name" {
  type        = string
  description = "Name for the Neo4j instance."
  default     = "neo4j-dev"
}

variable "neo4j_storage_size" {
  type        = string
  description = "Storage size for Neo4j data volume."
  default     = "25Gi"
}

variable "enable_neo4j_browser" {
  type        = bool
  description = "Enable HTTP for Neo4j Browser access (port 7474)."
  default     = true
}

variable "allowed_ingress_namespaces" {
  type        = list(string)
  description = "Additional namespaces allowed to access Neo4j (e.g., for monitoring, application pods)."
  default     = []
}

variable "neo4j_helm_repository" {
  type        = string
  description = "Helm repository URL for Neo4j chart."
  default     = "https://helm.neo4j.com/neo4j"
}

variable "neo4j_password_k8s_secret" {
  type        = string
  description = <<-EOT
    Name of an existing Kubernetes Secret containing the Neo4j password.
    If set, the password will NOT be fetched from Secret Manager into Terraform state.

    SECURITY: When null (default), the password is fetched from Secret Manager and
    passed to Helm, which stores it in Terraform state (encrypted by CMEK, but still
    present). For production, create the K8s secret externally (via CSI driver,
    External Secrets Operator, or kubectl) and provide its name here.

    The secret must have a key named 'NEO4J_AUTH' with value 'neo4j/<password>'.
  EOT
  default     = null
}

variable "backup_pod_label" {
  type        = string
  description = "Label value to identify backup pods for network policy. Pods with 'app.kubernetes.io/name' matching this value get backup network access."
  default     = "neo4j-backup"
}

variable "enable_external_access" {
  type        = bool
  description = <<-EOT
    Allow external access to Neo4j via the LoadBalancer.
    When true, NetworkPolicy permits ingress from any IP (0.0.0.0/0) on Bolt (7687)
    and optionally HTTP (7474) ports.

    WARNING: This exposes Neo4j to the internet. Ensure strong passwords and
    consider using master_authorized_networks on the GKE cluster for additional
    protection. For production, prefer VPN or bastion host access.
  EOT
  default     = false
}

# Direct password input for testing (bypasses Secret Manager)
variable "neo4j_password" {
  type        = string
  description = "Neo4j admin password (direct input). If set, takes precedence over Secret Manager lookup."
  sensitive   = true
  default     = null
}
