# Neo4j App Module

This module deploys Neo4j Enterprise to a GKE Autopilot cluster. It provisions Kubernetes resources and the Neo4j Helm chart.

**Requires Neo4j 2025.10+** for native Vector type support with Cypher 25.

## Resources Created

- Kubernetes namespace with environment labels
- Kubernetes service account with Workload Identity annotation
- IAM binding for Workload Identity (GSA ↔ KSA)
- NetworkPolicies:
  - `default-deny-all` - Blocks all traffic by default
  - `allow-neo4j` - Allows Bolt (7687) and optionally HTTP (7474) ingress
  - `allow-backup` - Allows backup pods to access Neo4j and GCS
  - `neo4j-to-backup-egress` - Allows Neo4j pods to reach backup pods on port 6362
- Neo4j Enterprise Helm release

## Usage

```hcl
module "neo4j" {
  source = "../../modules/neo4j_app"

  # Platform inputs (from other modules)
  project_id               = var.project_id
  workload_identity_pool   = module.gke.workload_identity_pool
  backup_gsa_email         = module.backup_sa.service_accounts["neo4j-backup"].email
  backup_gsa_name          = module.backup_sa.service_accounts["neo4j-backup"].name
  backup_bucket_url        = module.backup_bucket.bucket_url
  neo4j_password_secret_id = module.secrets.secret_ids["neo4j-admin-password-dev"]

  # Optional configuration
  neo4j_chart_version    = "2025.10.1"  # Requires 2025.10+ for Vector type
  neo4j_namespace        = "neo4j"
  neo4j_instance_name    = "neo4j-dev"
  neo4j_storage_size     = "25Gi"
  enable_neo4j_browser   = true
  enable_external_access = false  # Set true to allow LoadBalancer access

  depends_on = [module.gke]
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.9 |
| google | ~> 6.3 |
| kubernetes | ~> 2.35 |
| helm | ~> 2.17 |

## Providers

The calling environment must configure:

```hcl
provider "kubernetes" {
  host                   = "https://${module.gke.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| project_id | GCP project ID | `string` | n/a | yes |
| workload_identity_pool | Workload Identity pool (format: PROJECT_ID.svc.id.goog) | `string` | n/a | yes |
| backup_gsa_email | Email of the GCP service account for backups | `string` | n/a | yes |
| backup_gsa_name | Full resource name of the backup service account | `string` | n/a | yes |
| backup_bucket_url | GCS bucket URL for Neo4j backups | `string` | n/a | yes |
| neo4j_password_secret_id | Secret Manager secret ID for Neo4j password | `string` | `null` | no |
| neo4j_password | Direct password input (bypasses Secret Manager) | `string` | `null` | no |
| neo4j_password_k8s_secret | Name of existing K8s secret containing password | `string` | `null` | no |
| environment | Environment name (dev, staging, prod, test) | `string` | `"dev"` | no |
| neo4j_chart_version | Version of the Neo4j Helm chart (requires 2025.10+ for Vector type) | `string` | `"2025.10.1"` | no |
| neo4j_namespace | Kubernetes namespace for Neo4j | `string` | `"neo4j"` | no |
| neo4j_instance_name | Name for the Neo4j instance | `string` | `"neo4j-dev"` | no |
| neo4j_storage_size | Storage size for Neo4j data volume | `string` | `"25Gi"` | no |
| enable_neo4j_browser | Enable HTTP for Neo4j Browser (port 7474) | `bool` | `true` | no |
| enable_external_access | Allow external access via LoadBalancer (exposes to internet) | `bool` | `false` | no |
| allowed_ingress_namespaces | Additional namespaces allowed to access Neo4j | `list(string)` | `[]` | no |
| neo4j_helm_repository | Helm repository URL for Neo4j chart | `string` | `"https://helm.neo4j.com/neo4j"` | no |
| backup_pod_label | Label value to identify backup pods | `string` | `"neo4j-backup"` | no |

### Password Configuration

The module supports three password sources (in order of precedence):

1. **Direct input** (`neo4j_password`): For testing; password appears in state
2. **Secret Manager** (`neo4j_password_secret_id`): Fetches from GCP; password in state (encrypted by CMEK)
3. **K8s Secret** (`neo4j_password_k8s_secret`): External secret; password never in Terraform state

For production, use option 3 with External Secrets Operator or Secret Manager CSI driver.

## Outputs

| Name | Description |
|------|-------------|
| namespace | Kubernetes namespace where Neo4j is deployed |
| neo4j_instance_name | Name of the Neo4j instance |
| neo4j_bolt_service | Kubernetes service name for Bolt protocol |
| neo4j_bolt_port | Port for Neo4j Bolt protocol (7687) |
| backup_ksa_name | Kubernetes service account for backups |
| backup_bucket_url | GCS bucket URL for backups |
| connection_info | Neo4j connection information (URIs, username, password reference) |
| network_policy_default_deny | Name of the default-deny network policy |
| network_policy_allow_neo4j | Name of the allow-neo4j network policy |
| network_policy_allow_backup | Name of the allow-backup network policy |
| network_policy_neo4j_to_backup | Name of the neo4j-to-backup egress network policy |
| wi_binding_member | Workload Identity binding member string |

## Connecting to Neo4j

```bash
# Port-forward for local access
kubectl port-forward -n neo4j svc/neo4j-dev-lb-neo4j 7687:7687

# Connect with cypher-shell
cypher-shell -a bolt://localhost:7687 -u neo4j -p <password>
```

### Neo4j Browser (Web UI)

```bash
# Port-forward HTTP
kubectl port-forward -n neo4j svc/neo4j-dev-lb-neo4j 7474:7474

# Open in browser
open http://localhost:7474/browser
```

## Security

### NetworkPolicies

Default-deny policy blocks all traffic. Explicit rules allow:
- **Ingress**: Bolt (7687), HTTP (7474 if enabled) from same namespace + allowed namespaces
- **External access**: When `enable_external_access = true`, allows ingress from any IP (0.0.0.0/0)
- **Egress**: DNS (53), GKE metadata (169.254.169.254:80), HTTPS (443 for GCS)
- **Backup traffic**: Port 6362 between Neo4j and backup pods

**Note**: NetworkPolicies use `app=<instance_name>` label selector to match Neo4j pods, as this is the label scheme used by the Neo4j Helm chart (not the standard `app.kubernetes.io/name`).

### Pod Security Context

| Setting | Value | Purpose |
|---------|-------|---------|
| `runAsNonRoot` | `true` | Prevent running as root |
| `runAsUser/runAsGroup` | `7474` | Standard Neo4j UID |
| `fsGroup` | `7474` | Volume access |
| `seccompProfile` | `RuntimeDefault` | Seccomp sandboxing |
| `allowPrivilegeEscalation` | `false` | Prevent privilege escalation |
| `capabilities.drop` | `ALL` | Remove all Linux capabilities |

## Production TLS Configuration

Dev environment uses permissive TLS. For production:

```yaml
# In values/neo4j.yaml or via Helm set values
config:
  server.bolt.tls_level: "REQUIRED"
  server.http.enabled: "false"
  server.https.enabled: "true"
```

Provision certificates via cert-manager or external PKI.

## Tests

Run network policy validation tests:

```bash
cd infra/modules/neo4j_app
tofu init -backend=false
tofu test
```
