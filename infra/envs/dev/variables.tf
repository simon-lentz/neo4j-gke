variable "project_id" {
  type        = string
  description = "GCP project ID for the dev environment."
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.project_id))
    error_message = "project_id must match GCP constraints."
  }
}

variable "region" {
  type        = string
  description = "GCP region for resources."
  default     = "us-central1"
  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region (e.g., us-central1)."
  }
}

variable "subnet_ip_range" {
  type        = string
  description = "Primary IP CIDR range for the subnet."
  default     = "10.0.0.0/24"
}

variable "pods_ip_range" {
  type        = string
  description = "Secondary IP CIDR range for GKE pods."
  default     = "10.1.0.0/16"
}

variable "services_ip_range" {
  type        = string
  description = "Secondary IP CIDR range for GKE services."
  default     = "10.2.0.0/20"
}

variable "state_bucket" {
  type        = string
  description = "GCS bucket for OpenTofu state. Used to read bootstrap outputs for CMEK key."
}

# Neo4j Configuration
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
  description = "Additional namespaces allowed to access Neo4j."
  default     = []
}

variable "neo4j_password_k8s_secret" {
  type        = string
  description = <<-EOT
    Name of an existing Kubernetes Secret containing the Neo4j password.
    If set, the password will NOT be fetched from Secret Manager into Terraform state.
    For production, create the K8s secret externally and provide its name here.
  EOT
  default     = null
}

variable "deploy_neo4j_app" {
  type        = bool
  description = <<-EOT
    Whether to deploy the Neo4j application.

    Set to false (default) for initial infrastructure deployment.
    After creating the password in Secret Manager, set to true to deploy Neo4j.

    Two-phase deployment:
    1. tofu apply (deploy_neo4j_app=false) - creates VPC, GKE, secrets container
    2. gcloud secrets versions add neo4j-admin-password-dev --data-file=-
    3. tofu apply -var="deploy_neo4j_app=true" - deploys Neo4j
  EOT
  default     = false
}

variable "enable_external_access" {
  type        = bool
  description = <<-EOT
    Allow external access to Neo4j via the LoadBalancer.
    When true, NetworkPolicy permits ingress from any IP on Bolt and HTTP ports.

    WARNING: Exposes Neo4j to the internet. Use strong passwords.
  EOT
  default     = true
}
