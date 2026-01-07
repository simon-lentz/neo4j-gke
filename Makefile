# Makefile for neo4j-gke local development and testing
#
# Prerequisites:
#   - kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation
#   - kubectl: https://kubernetes.io/docs/tasks/tools/
#   - helm: https://helm.sh/docs/intro/install/

# Configuration - matches GKE deployment
# Neo4j 2025.10+ required for native Vector type support
NEO4J_CHART_VERSION ?= 2025.10.1
NEO4J_NAMESPACE     ?= neo4j
NEO4J_RELEASE_NAME  ?= neo4j-local
NEO4J_PASSWORD      ?= testpassword
KIND_CLUSTER_NAME   ?= neo4j-local

# Helm repository
NEO4J_HELM_REPO     := https://helm.neo4j.com/neo4j

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Local Kubernetes (kind) targets
# =============================================================================

.PHONY: kind-create
kind-create: ## Create kind cluster for local testing
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
		echo "Cluster '$(KIND_CLUSTER_NAME)' already exists"; \
	else \
		echo "Creating kind cluster '$(KIND_CLUSTER_NAME)'..."; \
		kind create cluster --name $(KIND_CLUSTER_NAME) --config local/kind-config.yaml; \
	fi
	@kubectl cluster-info --context kind-$(KIND_CLUSTER_NAME)

.PHONY: kind-delete
kind-delete: ## Delete kind cluster
	@echo "Deleting kind cluster '$(KIND_CLUSTER_NAME)'..."
	@kind delete cluster --name $(KIND_CLUSTER_NAME) || true

.PHONY: kind-context
kind-context: ## Switch kubectl context to kind cluster
	@kubectl config use-context kind-$(KIND_CLUSTER_NAME)

# =============================================================================
# Neo4j deployment targets
# =============================================================================

.PHONY: helm-repo
helm-repo: ## Add Neo4j Helm repository
	@helm repo add neo4j $(NEO4J_HELM_REPO) 2>/dev/null || true
	@helm repo update neo4j

.PHONY: neo4j-install
neo4j-install: kind-context helm-repo ## Install Neo4j to local kind cluster
	@echo "Creating namespace '$(NEO4J_NAMESPACE)'..."
	@kubectl create namespace $(NEO4J_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@echo "Installing Neo4j Enterprise $(NEO4J_CHART_VERSION)..."
	@helm upgrade --install $(NEO4J_RELEASE_NAME) neo4j/neo4j \
		--namespace $(NEO4J_NAMESPACE) \
		--version $(NEO4J_CHART_VERSION) \
		--values local/values-local.yaml \
		--set neo4j.password=$(NEO4J_PASSWORD) \
		--wait \
		--timeout 10m
	@echo ""
	@echo "Neo4j installed successfully!"
	@echo ""
	@echo "To access Neo4j from your host, run:"
	@echo "  make neo4j-port-forward"
	@echo ""
	@echo "Then connect via:"
	@echo "  Bolt:    bolt://localhost:17687"
	@echo "  Browser: http://localhost:17474"
	@echo "  User:    neo4j"
	@echo "  Password: $(NEO4J_PASSWORD)"

.PHONY: neo4j-uninstall
neo4j-uninstall: kind-context ## Uninstall Neo4j from local kind cluster
	@echo "Uninstalling Neo4j..."
	@helm uninstall $(NEO4J_RELEASE_NAME) --namespace $(NEO4J_NAMESPACE) || true
	@kubectl delete pvc --all --namespace $(NEO4J_NAMESPACE) || true
	@kubectl delete namespace $(NEO4J_NAMESPACE) || true

.PHONY: neo4j-status
neo4j-status: kind-context ## Show Neo4j deployment status
	@echo "=== Pods ==="
	@kubectl get pods -n $(NEO4J_NAMESPACE) -o wide
	@echo ""
	@echo "=== Services ==="
	@kubectl get svc -n $(NEO4J_NAMESPACE)
	@echo ""
	@echo "=== PVCs ==="
	@kubectl get pvc -n $(NEO4J_NAMESPACE)

.PHONY: neo4j-logs
neo4j-logs: kind-context ## Tail Neo4j logs
	@kubectl logs -f -n $(NEO4J_NAMESPACE) -l app=$(NEO4J_RELEASE_NAME) --tail=100

.PHONY: neo4j-shell
neo4j-shell: kind-context ## Open cypher-shell in Neo4j pod
	@kubectl exec -it -n $(NEO4J_NAMESPACE) \
		$$(kubectl get pod -n $(NEO4J_NAMESPACE) -l app=$(NEO4J_RELEASE_NAME) -o jsonpath='{.items[0].metadata.name}') \
		-- cypher-shell -u neo4j -p $(NEO4J_PASSWORD)

.PHONY: neo4j-port-forward
neo4j-port-forward: kind-context ## Port-forward Neo4j to localhost (Bolt:17687, HTTP:17474)
	@echo "Port-forwarding Neo4j to localhost..."
	@echo "  Bolt:    bolt://localhost:17687"
	@echo "  Browser: http://localhost:17474"
	@echo "  User:    neo4j"
	@echo "  Password: $(NEO4J_PASSWORD)"
	@echo ""
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n $(NEO4J_NAMESPACE) svc/$(NEO4J_RELEASE_NAME) 17687:7687 17474:7474

# =============================================================================
# Testing targets
# =============================================================================

.PHONY: neo4j-test
neo4j-test: kind-context ## Run basic connectivity test against local Neo4j
	@echo "Testing Neo4j connectivity..."
	@echo ""
	@echo "=== Checking pod readiness ==="
	@kubectl wait --for=condition=ready pod -n $(NEO4J_NAMESPACE) -l app=$(NEO4J_RELEASE_NAME) --timeout=60s
	@echo ""
	@echo "=== Testing Bolt connection ==="
	@kubectl exec -n $(NEO4J_NAMESPACE) \
		$$(kubectl get pod -n $(NEO4J_NAMESPACE) -l app=$(NEO4J_RELEASE_NAME) -o jsonpath='{.items[0].metadata.name}') \
		-- cypher-shell -u neo4j -p $(NEO4J_PASSWORD) "RETURN 'Neo4j is running' AS status;"
	@echo ""
	@echo "=== Checking Neo4j version ==="
	@kubectl exec -n $(NEO4J_NAMESPACE) \
		$$(kubectl get pod -n $(NEO4J_NAMESPACE) -l app=$(NEO4J_RELEASE_NAME) -o jsonpath='{.items[0].metadata.name}') \
		-- cypher-shell -u neo4j -p $(NEO4J_PASSWORD) "CALL dbms.components() YIELD name, versions RETURN name, versions;"
	@echo ""
	@echo "=== Testing Cypher 25 and native Vector type ==="
	@kubectl exec -n $(NEO4J_NAMESPACE) \
		$$(kubectl get pod -n $(NEO4J_NAMESPACE) -l app=$(NEO4J_RELEASE_NAME) -o jsonpath='{.items[0].metadata.name}') \
		-- cypher-shell -u neo4j -p $(NEO4J_PASSWORD) "RETURN vector([1.0, 2.0, 3.0], 3, FLOAT32) AS vec;"
	@echo ""
	@echo "=== Testing Vector similarity ==="
	@kubectl exec -n $(NEO4J_NAMESPACE) \
		$$(kubectl get pod -n $(NEO4J_NAMESPACE) -l app=$(NEO4J_RELEASE_NAME) -o jsonpath='{.items[0].metadata.name}') \
		-- cypher-shell -u neo4j -p $(NEO4J_PASSWORD) "WITH vector([1.0, 0.0], 2, FLOAT32) AS v1, vector([1.0, 0.0], 2, FLOAT32) AS v2 RETURN vector.similarity.cosine(v1, v2) AS similarity;"
	@echo ""
	@echo "All tests passed!"

.PHONY: neo4j-test-ephemeral
neo4j-test-ephemeral: ## Run tests in ephemeral cluster (creates, tests, destroys)
	@echo "=== Starting ephemeral Neo4j test ==="
	@trap 'echo ""; echo "=== Cleaning up ==="; $(MAKE) local-down' EXIT; \
	$(MAKE) local-up && $(MAKE) neo4j-test
	@echo ""
	@echo "=== Ephemeral test complete ==="

.PHONY: neo4j-test-networkpolicy
neo4j-test-networkpolicy: kind-context ## Test NetworkPolicy enforcement (requires Calico)
	@echo "Testing NetworkPolicy..."
	@echo "Note: kind's default CNI (kindnet) has limited NetworkPolicy support."
	@echo "For full testing, install Calico: make calico-install"
	@echo ""
	@kubectl get networkpolicies -n $(NEO4J_NAMESPACE) 2>/dev/null || echo "No NetworkPolicies found"

# =============================================================================
# Optional: Calico for NetworkPolicy support
# =============================================================================

.PHONY: calico-install
calico-install: kind-context ## Install Calico CNI for full NetworkPolicy support
	@echo "Installing Calico..."
	@kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
	@echo "Waiting for Calico to be ready..."
	@kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=120s

# =============================================================================
# Convenience targets
# =============================================================================

.PHONY: local-up
local-up: kind-create neo4j-install ## Create kind cluster and install Neo4j (full setup)

.PHONY: local-down
local-down: neo4j-uninstall kind-delete ## Tear down everything (Neo4j + kind cluster)

.PHONY: local-reset
local-reset: neo4j-uninstall neo4j-install ## Reset Neo4j (uninstall and reinstall)

# =============================================================================
# OpenTofu targets (existing infrastructure)
# =============================================================================

.PHONY: fmt
fmt: ## Format OpenTofu files
	@tofu fmt -recursive infra/

.PHONY: validate
validate: ## Validate OpenTofu modules
	@for dir in infra/modules/*; do \
		if [ -d "$$dir" ]; then \
			echo "Validating $$dir..."; \
			(cd "$$dir" && tofu init -backend=false -input=false >/dev/null && tofu validate); \
		fi \
	done

.PHONY: lint
lint: fmt validate ## Run all linting (format + validate)
	@pre-commit run --all-files

.PHONY: test
test: ## Run Go integration tests (short mode)
	@cd test && go test -v -short ./...

.PHONY: test-all
test-all: ## Run all Go integration tests
	@cd test && go test -v -timeout 30m ./...
