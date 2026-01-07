# Neo4j Application Module
#
# This module deploys Neo4j to a GKE cluster. It configures:
# - Kubernetes namespace with labels
# - Service account with Workload Identity for backups
# - NetworkPolicies for security
# - Neo4j Helm release

# Read Neo4j admin password from Secret Manager
# SECURITY WARNING: This stores the password in Terraform state (encrypted by CMEK).
# For production, use neo4j_password_k8s_secret variable with externally-managed secret
# (via Secret Manager CSI driver, External Secrets Operator, or kubectl).
data "google_secret_manager_secret_version" "neo4j_password" {
  count   = var.neo4j_password_k8s_secret == null && var.neo4j_password == null && var.neo4j_password_secret_id != null ? 1 : 0
  project = var.project_id
  secret  = var.neo4j_password_secret_id
}

# Determine password source: direct input > Secret Manager > K8s secret
locals {
  use_secret_manager = var.neo4j_password == null && var.neo4j_password_k8s_secret == null && var.neo4j_password_secret_id != null
  effective_password = var.neo4j_password != null ? var.neo4j_password : (local.use_secret_manager ? data.google_secret_manager_secret_version.neo4j_password[0].secret_data : null)
}

# Kubernetes namespace for Neo4j
resource "kubernetes_namespace" "neo4j" {
  metadata {
    name = var.neo4j_namespace
    labels = {
      "app.kubernetes.io/name"       = "neo4j"
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

# Kubernetes Service Account for backups with Workload Identity annotation
resource "kubernetes_service_account" "neo4j_backup" {
  metadata {
    name      = "neo4j-backup"
    namespace = kubernetes_namespace.neo4j.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = var.backup_gsa_email
    }
    labels = {
      "app.kubernetes.io/name"       = "neo4j-backup"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Workload Identity binding: GSA -> KSA
resource "google_service_account_iam_member" "backup_wi_binding" {
  service_account_id = var.backup_gsa_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${kubernetes_namespace.neo4j.metadata[0].name}/${kubernetes_service_account.neo4j_backup.metadata[0].name}]"
}

# Default deny NetworkPolicy - block all traffic by default
resource "kubernetes_network_policy" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.neo4j.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

# Allow Neo4j internal traffic
resource "kubernetes_network_policy" "allow_neo4j" {
  metadata {
    name      = "allow-neo4j"
    namespace = kubernetes_namespace.neo4j.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        # Neo4j Helm chart uses "app" label, not "app.kubernetes.io/name"
        "app" = var.neo4j_instance_name
      }
    }

    # Allow Bolt protocol (7687) and optionally HTTP browser (7474) ingress
    ingress {
      ports {
        port     = "7687"
        protocol = "TCP"
      }
      dynamic "ports" {
        for_each = var.enable_neo4j_browser ? [1] : []
        content {
          port     = "7474"
          protocol = "TCP"
        }
      }
      # Allow from same namespace
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.neo4j_namespace
          }
        }
      }
      # Allow from additional namespaces
      dynamic "from" {
        for_each = var.allowed_ingress_namespaces
        content {
          namespace_selector {
            match_labels = {
              "kubernetes.io/metadata.name" = from.value
            }
          }
        }
      }
      # Allow external access via LoadBalancer (when enabled)
      dynamic "from" {
        for_each = var.enable_external_access ? [1] : []
        content {
          ip_block {
            cidr = "0.0.0.0/0"
          }
        }
      }
    }

    # Allow egress for backups to GCS and DNS resolution
    egress {
      # DNS
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    egress {
      # Metadata server for GKE Workload Identity token exchange
      ports {
        port     = "80"
        protocol = "TCP"
      }
      to {
        ip_block {
          cidr = "169.254.169.254/32"
        }
      }
    }

    egress {
      # HTTPS for GCS access
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress", "Egress"]
  }
}

# Allow backup pods to access Neo4j backup port and external services
resource "kubernetes_network_policy" "allow_backup" {
  metadata {
    name      = "allow-backup"
    namespace = kubernetes_namespace.neo4j.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = var.backup_pod_label
      }
    }

    # Allow ingress from Neo4j pods on backup port 6362
    ingress {
      ports {
        port     = "6362"
        protocol = "TCP"
      }
      from {
        pod_selector {
          match_labels = {
            # Neo4j Helm chart uses "app" label
            "app" = var.neo4j_instance_name
          }
        }
      }
    }

    # Allow egress for backup operations
    egress {
      # DNS resolution
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    egress {
      # Metadata server for GKE Workload Identity token exchange
      ports {
        port     = "80"
        protocol = "TCP"
      }
      to {
        ip_block {
          cidr = "169.254.169.254/32"
        }
      }
    }

    egress {
      # HTTPS for GCS backup uploads
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress", "Egress"]
  }
}

# Allow Neo4j pods to connect to backup pods on port 6362
resource "kubernetes_network_policy" "neo4j_to_backup" {
  metadata {
    name      = "neo4j-to-backup-egress"
    namespace = kubernetes_namespace.neo4j.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        # Neo4j Helm chart uses "app" label
        "app" = var.neo4j_instance_name
      }
    }

    # Allow egress to backup pods on port 6362
    egress {
      ports {
        port     = "6362"
        protocol = "TCP"
      }
      to {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = var.backup_pod_label
          }
        }
      }
    }

    policy_types = ["Egress"]
  }
}

# Neo4j Helm release
resource "helm_release" "neo4j" {
  name       = var.neo4j_instance_name
  repository = var.neo4j_helm_repository
  chart      = "neo4j"
  version    = var.neo4j_chart_version
  namespace  = kubernetes_namespace.neo4j.metadata[0].name

  # Use values file for base configuration
  values = [file("${path.module}/values/neo4j.yaml")]

  # Override sensitive values - only when using direct password or Secret Manager
  dynamic "set_sensitive" {
    for_each = local.effective_password != null ? [1] : []
    content {
      name  = "neo4j.password"
      value = local.effective_password
    }
  }

  # Use existing K8s secret for password (avoids secret in Terraform state)
  dynamic "set" {
    for_each = var.neo4j_password_k8s_secret != null ? [1] : []
    content {
      name  = "neo4j.passwordFromSecret"
      value = var.neo4j_password_k8s_secret
    }
  }

  # Override instance name
  set {
    name  = "neo4j.name"
    value = var.neo4j_instance_name
  }

  # Override storage size
  set {
    name  = "volumes.data.defaultStorageClass.requests.storage"
    value = var.neo4j_storage_size
  }

  # Override HTTP browser setting (controlled by enable_neo4j_browser variable)
  set {
    name  = "config.server\\.http\\.enabled"
    value = var.enable_neo4j_browser ? "true" : "false"
    type  = "string"
  }

  # Ensure services.default.enabled is passed as a string
  set {
    name  = "services.default.enabled"
    value = "true"
    type  = "string"
  }

  # Ensure services.neo4j.enabled is passed as a string
  set {
    name  = "services.neo4j.enabled"
    value = "false"
    type  = "string"
  }

  # Ensure services.admin.enabled is passed as a string
  set {
    name  = "services.admin.enabled"
    value = "true"
    type  = "string"
  }

  depends_on = [
    kubernetes_namespace.neo4j,
    kubernetes_network_policy.allow_neo4j
  ]

  timeout = 600 # 10 minutes for initial deployment
}
