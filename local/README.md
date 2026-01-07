# Local Kubernetes Testing

This directory contains configuration for testing Neo4j deployments locally using [kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker).

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

## Quick Start

```bash
# From repository root

# Run ephemeral test (creates cluster, tests, cleans up automatically)
make neo4j-test-ephemeral

# Or for persistent development:
make local-up              # Create cluster and install Neo4j
make neo4j-status          # Check status
make neo4j-test            # Run connectivity tests
make neo4j-shell           # Interactive cypher-shell
make neo4j-port-forward    # Access from host (separate terminal)
make local-down            # Tear down when done
```

### Ephemeral vs Persistent

| Mode | Command | Use Case |
|------|---------|----------|
| **Ephemeral** | `make neo4j-test-ephemeral` | CI/CD, quick validation, no cleanup needed |
| **Persistent** | `make local-up` | Development, debugging, manual testing |

### Accessing Neo4j (persistent mode)

```bash
# In a separate terminal
make neo4j-port-forward

# Then connect:
# Browser: http://localhost:17474
# Bolt:    bolt://localhost:17687
# User:    neo4j
# Password: testpassword (override with NEO4J_PASSWORD=xxx)
```

**Note:** Ports 17474/17687 are used to avoid conflicts with local Neo4j installations.

## Parity with GKE Deployment

The local configuration mirrors the GKE deployment as closely as possible:

| Setting | Local | GKE |
|---------|-------|-----|
| Edition | Enterprise | Enterprise |
| Chart version | 2025.10.1 | 2025.10.1 |
| Cypher version | 25 | 25 |
| Native Vector type | Supported | Supported |
| Storage | 10Gi | 10Gi |
| CPU request | 500m | 500m |
| Memory request | 2Gi | 2Gi |
| Security context | Same | Same |
| Backup listener | Enabled | Enabled |

### What's Different Locally

| Feature | Local | GKE | Reason |
|---------|-------|-----|--------|
| Service type | NodePort | ClusterIP | kind needs NodePort for host access |
| Workload Identity | N/A | Enabled | GCP-specific |
| GCS backups | N/A | Enabled | GCP-specific |
| NetworkPolicy enforcement | Limited | Full | kind's default CNI has basic support |

## Make Targets

```bash
make help                    # Show all targets

# Cluster management
make kind-create             # Create kind cluster
make kind-delete             # Delete kind cluster
make kind-context            # Switch kubectl to kind cluster

# Neo4j deployment
make neo4j-install           # Install Neo4j
make neo4j-uninstall         # Uninstall Neo4j
make neo4j-status            # Show deployment status
make neo4j-logs              # Tail Neo4j logs
make neo4j-shell             # Open cypher-shell
make neo4j-port-forward      # Port-forward to localhost:17474/17687

# Testing
make neo4j-test              # Run connectivity tests (requires running cluster)
make neo4j-test-ephemeral    # Full test with auto-cleanup (CI/CD friendly)
make neo4j-test-networkpolicy # Check NetworkPolicy status

# Convenience
make local-up                # Full setup (cluster + Neo4j)
make local-down              # Full teardown
make local-reset             # Reinstall Neo4j
```

## Configuration

Override defaults via environment variables:

```bash
# Custom password
NEO4J_PASSWORD=mysecret make local-up

# Different chart version (must be 2025.10+ for Vector type support)
NEO4J_CHART_VERSION=2025.10.1 make neo4j-install

# Custom namespace
NEO4J_NAMESPACE=graph-db make neo4j-install
```

## NetworkPolicy Testing

kind's default CNI (kindnet) has limited NetworkPolicy support. For full NetworkPolicy testing:

```bash
# Install Calico CNI
make calico-install

# Then deploy Neo4j with NetworkPolicies
# (would require applying the policies from infra/modules/neo4j_app/)
```

## Files

- `kind-config.yaml` - kind cluster configuration with port mappings
- `values-local.yaml` - Helm values mirroring GKE deployment
