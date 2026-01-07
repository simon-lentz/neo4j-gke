# Neo4j Network Policy Plan Tests
#
# These tests validate the network policy configuration without deploying.
# They verify that backup ports (6362) and pod selectors are correctly configured.
#
# Run with: tofu test

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "google" {}

variables {
  project_id             = "test-project"
  workload_identity_pool = "test-project.svc.id.goog"
  backup_gsa_email       = "backup@test-project.iam.gserviceaccount.com"
  backup_gsa_name        = "projects/test-project/serviceAccounts/backup@test-project.iam.gserviceaccount.com"
  backup_bucket_url      = "gs://test-project-backup"
  neo4j_password         = "test-password"
  neo4j_namespace        = "neo4j"
  neo4j_instance_name    = "neo4j-dev"
  backup_pod_label       = "neo4j-backup"
}

# Test: Default deny policy exists
run "default_deny_policy_created" {
  command = plan

  assert {
    condition     = kubernetes_network_policy.default_deny.metadata[0].name == "default-deny-all"
    error_message = "Default deny policy should be named 'default-deny-all'"
  }

  assert {
    condition     = contains(kubernetes_network_policy.default_deny.spec[0].policy_types, "Ingress")
    error_message = "Default deny policy should block Ingress"
  }

  assert {
    condition     = contains(kubernetes_network_policy.default_deny.spec[0].policy_types, "Egress")
    error_message = "Default deny policy should block Egress"
  }
}

# Test: Backup network policy allows port 6362
run "backup_policy_allows_port_6362" {
  command = plan

  assert {
    condition     = kubernetes_network_policy.allow_backup.metadata[0].name == "allow-backup"
    error_message = "Backup policy should be named 'allow-backup'"
  }

  assert {
    condition     = kubernetes_network_policy.allow_backup.spec[0].ingress[0].ports[0].port == "6362"
    error_message = "Backup policy should allow ingress on port 6362"
  }

  assert {
    condition     = kubernetes_network_policy.allow_backup.spec[0].ingress[0].ports[0].protocol == "TCP"
    error_message = "Backup policy should use TCP protocol"
  }
}

# Test: Backup policy pod selector uses correct label
run "backup_policy_pod_selector" {
  command = plan

  assert {
    condition     = kubernetes_network_policy.allow_backup.spec[0].pod_selector[0].match_labels["app.kubernetes.io/name"] == "neo4j-backup"
    error_message = "Backup policy should select pods with label app.kubernetes.io/name=neo4j-backup"
  }
}

# Test: Backup policy allows egress for DNS, metadata, and HTTPS
run "backup_policy_egress_rules" {
  command = plan

  # Egress rule count: DNS (1) + Metadata (1) + HTTPS (1) = 3
  assert {
    condition     = length(kubernetes_network_policy.allow_backup.spec[0].egress) == 3
    error_message = "Backup policy should have 3 egress rules (DNS, metadata, HTTPS)"
  }

  assert {
    condition     = contains(kubernetes_network_policy.allow_backup.spec[0].policy_types, "Egress")
    error_message = "Backup policy should include Egress in policy_types"
  }
}

# Test: Neo4j to backup egress policy exists
run "neo4j_to_backup_egress_policy" {
  command = plan

  assert {
    condition     = kubernetes_network_policy.neo4j_to_backup.metadata[0].name == "neo4j-to-backup-egress"
    error_message = "Neo4j to backup policy should be named 'neo4j-to-backup-egress'"
  }

  assert {
    condition     = kubernetes_network_policy.neo4j_to_backup.spec[0].egress[0].ports[0].port == "6362"
    error_message = "Neo4j to backup policy should allow egress on port 6362"
  }

  # Note: Neo4j Helm chart uses "app" label, not "app.kubernetes.io/name"
  assert {
    condition     = kubernetes_network_policy.neo4j_to_backup.spec[0].pod_selector[0].match_labels["app"] == "neo4j-dev"
    error_message = "Neo4j to backup policy should select Neo4j pods using 'app' label"
  }
}

# Test: Allow Neo4j policy includes Bolt port and correct pod selector
run "neo4j_policy_allows_bolt" {
  command = plan

  assert {
    condition     = kubernetes_network_policy.allow_neo4j.spec[0].ingress[0].ports[0].port == "7687"
    error_message = "Neo4j policy should allow Bolt protocol on port 7687"
  }

  # Note: Neo4j Helm chart uses "app" label, not "app.kubernetes.io/name"
  assert {
    condition     = kubernetes_network_policy.allow_neo4j.spec[0].pod_selector[0].match_labels["app"] == "neo4j-dev"
    error_message = "Neo4j policy should select Neo4j pods using 'app' label"
  }
}
