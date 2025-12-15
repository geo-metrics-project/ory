#!/bin/bash
set -euo pipefail

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_step() { echo -e "${BLUE}==>${NC} $1"; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Namespaces
INFRA_NAMESPACE="geo-infra"
ORY_NAMESPACE="geo-ory"
APP_NAMESPACE="geo-app"

RELEASE_NAME="${RELEASE_NAME:-geo-metrics}"

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites"
    
    # Check if PostgreSQL StatefulSet is running
    if ! kubectl get statefulset ${RELEASE_NAME}-postgresql -n "$INFRA_NAMESPACE" &>/dev/null; then
        log_error "PostgreSQL not found in namespace '$INFRA_NAMESPACE'"
        log_error "Please run 'make setup-core' first"
        exit 1
    fi
    
    # Check if PostgreSQL pod is running
    local pg_pod_status=$(kubectl get pods -n "$INFRA_NAMESPACE" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$pg_pod_status" != "Running" ]]; then
        log_error "PostgreSQL pod is not running (status: ${pg_pod_status:-NotFound})"
        log_error "Please ensure PostgreSQL is running: kubectl get pods -n $INFRA_NAMESPACE"
        exit 1
    fi
    
    log_info "PostgreSQL is running"
    
    # Check if database secrets exist
    for secret in kratos-db-credentials hydra-db-credentials; do
        if ! kubectl get secret "$secret" -n "$ORY_NAMESPACE" &>/dev/null; then
            log_error "Secret '$secret' not found in namespace '$ORY_NAMESPACE'"
            log_error "Please run 'make setup-core' first to create database secrets"
            exit 1
        fi
    done
    
    log_info "All database secrets found"
    log_info "All prerequisites met"
}

# Install Oathkeeper Maester CRDs
install_oathkeeper_crds() {
    log_step "Installing Oathkeeper Maester CRDs"
    
    # Check if CRD already exists
    if kubectl get crd rules.oathkeeper.ory.sh &>/dev/null; then
        log_info "Oathkeeper CRDs already installed"
        return
    fi
    
    kubectl apply -f https://raw.githubusercontent.com/ory/oathkeeper-maester/master/config/crd/bases/oathkeeper.ory.sh_rules.yaml
    
    log_info "Oathkeeper CRDs installed"
}

# Generate secure random secrets
generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

# Deploy Kratos (Identity Management)
deploy_kratos() {
    log_step "Deploying Ory Kratos to $ORY_NAMESPACE"
    
    # Get DSN from secret created by setup-core.sh
    local dsn=$(kubectl get secret kratos-db-credentials -n "$ORY_NAMESPACE" -o jsonpath='{.data.dsn}' | base64 -d)
    
    # Generate secrets
    local cookie_secret=$(generate_secret)
    local cipher_secret=$(generate_secret)
    
    if [[ ! -f "$PROJECT_ROOT/helm/values/values-kratos.yaml" ]]; then
        log_error "Kratos values file not found: helm/values/values-kratos.yaml"
        exit 1
    fi
    
    helm upgrade --install kratos ory/kratos \
        --namespace "$ORY_NAMESPACE" \
        -f "$PROJECT_ROOT/helm/values/values-kratos.yaml" \
        --set kratos.config.dsn="$dsn" \
        --set kratos.config.secrets.cookie[0]="$cookie_secret" \
        --set kratos.config.secrets.cipher[0]="$cipher_secret" \
        --wait --timeout=5m
    
    log_info "Kratos deployed"
}

# Deploy Hydra (OAuth2/OIDC)
deploy_hydra() {
    log_step "Deploying Ory Hydra to $ORY_NAMESPACE"
    
    # Get DSN from secret created by setup-core.sh
    local dsn=$(kubectl get secret hydra-db-credentials -n "$ORY_NAMESPACE" -o jsonpath='{.data.dsn}' | base64 -d)
    
    # Generate secrets
    local system_secret=$(generate_secret)
    local cookie_secret=$(generate_secret)
    
    if [[ ! -f "$PROJECT_ROOT/helm/values/values-hydra.yaml" ]]; then
        log_error "Hydra values file not found: helm/values/values-hydra.yaml"
        exit 1
    fi
    
    helm upgrade --install hydra ory/hydra \
        --namespace "$ORY_NAMESPACE" \
        -f "$PROJECT_ROOT/helm/values/values-hydra.yaml" \
        --set hydra.config.dsn="$dsn" \
        --set hydra.config.secrets.system[0]="$system_secret" \
        --set hydra.config.secrets.cookie[0]="$cookie_secret" \
        --wait --timeout=5m
    
    log_info "Hydra deployed"
}

# Deploy Keto (Permissions)
deploy_keto() {
    log_step "Deploying Ory Keto to $ORY_NAMESPACE"

    local dsn=$(kubectl get secret keto-db-credentials -n "$ORY_NAMESPACE" -o jsonpath='{.data.dsn}' | base64 -d)
    
    helm upgrade --install keto ory/keto \
        --namespace "$ORY_NAMESPACE" \
        -f "$PROJECT_ROOT/helm/values/values-keto.yaml" \
        --set keto.config.dsn="$dsn" \
        --wait --timeout=5m
    
    log_info "Keto deployed"
}

# Deploy Oathkeeper (API Gateway)
deploy_oathkeeper() {
    log_step "Deploying Ory Oathkeeper to $ORY_NAMESPACE"
    
    install_oathkeeper_crds

    apply_access_rules
    
    if [[ ! -f "$PROJECT_ROOT/helm/values/values-oathkeeper.yaml" ]]; then
        log_error "Oathkeeper values file not found: helm/values/values-oathkeeper.yaml"
        exit 1
    fi
    
    helm upgrade --install oathkeeper ory/oathkeeper \
        --namespace "$ORY_NAMESPACE" \
        -f "$PROJECT_ROOT/helm/values/values-oathkeeper.yaml" \
        --wait --timeout=5m \
        --skip-crds
    
    log_info "Oathkeeper deployed"
}

# Apply Oathkeeper access rules
apply_access_rules() {
    log_step "Applying Oathkeeper access rules"
    
    local rules_dir="$PROJECT_ROOT/k8s/crds/oathkeeper/rules"
    
    if [[ ! -d "$rules_dir" ]]; then
        log_warn "Rules directory not found: $rules_dir"
        log_warn "Skipping access rules application"
        log_warn "Create rules in: $rules_dir"
        return
    fi
    
    if [[ -z "$(ls -A $rules_dir/*.yaml 2>/dev/null)" ]]; then
        log_warn "No rule files found in $rules_dir"
        log_warn "Skipping access rules application"
        return
    fi
    
    kubectl apply -f "$rules_dir/"
    
    log_info "Access rules applied"
}

# Display connection info
show_connection_info() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Ory Services Information"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo "🔐 Deployed Services:"
    echo "  • Kratos (Identity Management)"
    echo "  • Hydra (OAuth2/OIDC)"
    echo "  • Oathkeeper (API Gateway)"
    
    if kubectl get deployment keto -n "$ORY_NAMESPACE" &>/dev/null; then
        echo "  • Keto (Permissions)"
    fi
    echo ""
    
    echo "🌐 Service URLs:"
    echo "  • Kratos:     https://auth.combaldieu.fr"
    echo "  • Hydra:      https://oauth.combaldieu.fr"
    echo "  • Oathkeeper: https://gateway.combaldieu.fr"
    echo ""
    
    echo "🔍 Check deployment status:"
    echo "  kubectl get pods -n $ORY_NAMESPACE"
    echo "  kubectl get ingress -n $ORY_NAMESPACE"
    echo ""
    
    echo "📝 Get database connection strings:"
    echo "  kubectl get secret kratos-db-credentials -n $ORY_NAMESPACE -o jsonpath='{.data.dsn}' | base64 -d"
    echo "  kubectl get secret hydra-db-credentials -n $ORY_NAMESPACE -o jsonpath='{.data.dsn}' | base64 -d"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
    log_step "Setting up Ory authentication stack"
    echo ""
    
    check_prerequisites
    echo ""
    
    deploy_kratos
    echo ""
    
    deploy_hydra
    echo ""
    
    deploy_keto
    echo ""
    
    deploy_oathkeeper
    echo ""
    
    log_info "Ory stack setup complete! 🎉"
    
    show_connection_info
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi