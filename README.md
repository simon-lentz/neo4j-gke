# Neo4j on GKE Autopilot

Infrastructure-as-code for deploying Neo4j Enterprise on Google Kubernetes Engine (GKE) Autopilot.

## Overview

This repository provisions a **single-instance Neo4j Enterprise** deployment on **GKE Autopilot** using OpenTofu, designed for dev/POC/MVP workloads. It implements:

- **Neo4j 2025.x** with Cypher 25 as the default query language
- **Private-by-default** networking (no public exposure)
- **Workload Identity** for secure GCS backup access
- **Secret Manager** integration for credentials

> **Important:** This is a dev deployment with **no SLA guarantees**. Data loss is an accepted risk.

## Repository Structure

```text
.
├── infra/
│   ├── envs/              # Platform layer (GCP resources)
│   │   ├── bootstrap/     # One-time: creates GCS state bucket
│   │   └── dev/           # Dev: VPC, GKE, IAM, secrets, buckets
│   │
│   ├── apps/              # Application layer (K8s deployments)
│   │   └── neo4j/         # Neo4j Helm deployment
│   │       └── dev/
│   │
│   └── modules/           # Reusable OpenTofu modules
│       ├── vpc/
│       ├── gke/
│       ├── secrets/
│       ├── backup_bucket/
│       ├── audit_logging/
│       ├── service_accounts/
│       ├── wif/
│       └── bootstrap/
│
└── test/                  # Go integration tests (Terratest)
```

## Architecture

The infrastructure uses a **two-layer model**:

| Layer | Directory | Purpose | State Prefix |
| ----- | --------- | ------- | ------------ |
| **Platform** | `infra/envs/dev/` | GCP primitives (VPC, GKE, IAM, GCS) | `dev` |
| **Apps** | `infra/apps/neo4j/dev/` | K8s resources + Helm releases | `apps/neo4j/dev` |

The apps layer reads platform outputs via `terraform_remote_state`, keeping ownership boundaries clear.

## Quick Start

### Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.9.1
- [gcloud CLI](https://cloud.google.com/sdk/gcloud) authenticated
- GCP project with billing enabled

## Development Setup

### Pre-commit Hooks

Install pre-commit hooks and formatting dependencies:

```bash
# Install pre-commit
pip install pre-commit

# Install hclfmt (required for HCL formatting)
go install github.com/hashicorp/hcl/v2/cmd/hclfmt@latest

# Install hooks
pre-commit install
```

### Running Tests

```bash
cd test
go test -v -short ./...  # Quick validation (skips long-running tests)
go test -v -timeout 30m ./...  # Integration tests (VPC, GKE, etc.)

# End-to-end tests (deploys full Neo4j stack, ~45 min)
go test -tags=e2e -timeout 45m -v ./test/e2e/...
```

### 1. Bootstrap (one-time)

Bootstrap using the guide in the `bootstrap` module's [README](./infra/modules/bootstrap/README.md).

### 2. Deploy Platform

```bash
cd infra/envs/dev
tofu init -backend-config="bucket=YOUR_STATE_BUCKET"
tofu apply -var="project_id=YOUR_PROJECT"
```

### 3. Set Neo4j Password

```bash
echo -n "your-secure-password" | \
  gcloud secrets versions add neo4j-admin-password-dev --data-file=-
```

### 4. Deploy Neo4j

```bash
cd infra/apps/neo4j/dev
tofu init -backend-config="bucket=YOUR_STATE_BUCKET"
tofu apply \
  -var="project_id=YOUR_PROJECT" \
  -var="state_bucket=YOUR_STATE_BUCKET"
```

### 5. Connect

```bash
# Port-forward for Bolt protocol (programmatic access)
kubectl port-forward -n neo4j svc/neo4j-dev-lb-neo4j 7687:7687

# Port-forward for Neo4j Browser (web UI)
kubectl port-forward -n neo4j svc/neo4j-dev-lb-neo4j 7474:7474

# Connect via cypher-shell
cypher-shell -a bolt://localhost:7687 -u neo4j -p <password>

# Or open Neo4j Browser
open http://localhost:7474/browser
```

## Documentation

### Module Documentation

| Module | Description |
| ------ | ----------- |
| [vpc](infra/modules/vpc/README.md) | VPC, subnet, Cloud NAT |
| [gke](infra/modules/gke/README.md) | GKE Autopilot cluster |
| [secrets](infra/modules/secrets/README.md) | Secret Manager secrets |
| [backup_bucket](infra/modules/backup_bucket/README.md) | GCS bucket for backups |
| [audit_logging](infra/modules/audit_logging/README.md) | KMS/GCS audit logging |
| [service_accounts](infra/modules/service_accounts/README.md) | GCP service accounts |
| [wif](infra/modules/wif/README.md) | Workload Identity Federation |
| [bootstrap](infra/modules/bootstrap/README.md) | State bucket bootstrap |

### Application Documentation

| App | Description |
| --- | ----------- |
| [neo4j](infra/apps/neo4j/README.md) | Neo4j Helm deployment |

## Testing

Run integration tests (requires GCP credentials -> `gcloud auth application-default login`):

```bash
# Set environment
export NEO4J_GKE_GCP_PROJECT_ID="your-project-id"
export NEO4J_GKE_STATE_BUCKET_LOCATION="us-central1"

# Run unit/integration tests
go test -v ./test/...

# Run end-to-end tests (full Neo4j deployment, ~45 min)
go test -tags=e2e -timeout 45m -v ./test/e2e/...

# Or, save test output for review
go test -v ./test/... --json > gotest.jsonl
```

**Test Categories:**

- `test/` - Module integration tests (VPC, GKE, secrets, etc.)
- `test/e2e/` - Full end-to-end tests requiring `//go:build e2e` tag

## Security

- **No public endpoints** - All services are ClusterIP (internal only)
- **Workload Identity** - No exported service account keys
- **Secret Manager** - Credentials never stored in Terraform state
- **NetworkPolicies** - Default-deny with explicit allow rules
- **UBLA + PAP** - Buckets use uniform access and block public access

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.
