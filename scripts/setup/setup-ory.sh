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

# Namespace
ORY_NAMESPACE="geo-ory"

# Create infra namespace if it doesn't exist
create_namespace() {
    log_step "Ensuring infra namespace exists"

    if kubectl get namespace "$ORY_NAMESPACE" &>/dev/null; then
        log_info "Namespace '$ORY_NAMESPACE' already exists"
    else
        kubectl create namespace "$ORY_NAMESPACE"
        log_info "Created namespace '$ORY_NAMESPACE'"
    fi
}

deploy_postgres() {
    log_step "Deploying PostgreSQL to $ORY_NAMESPACE"

    # Generate random password for each DB user
    local kratos_pwd=$(generate_secret)
    local keto_pwd=$(generate_secret)

    # Create init script
    local init_sql=$(cat <<EOF
CREATE USER kratos WITH PASSWORD '$kratos_pwd';
CREATE DATABASE kratos OWNER kratos;
CREATE USER keto WITH PASSWORD '$keto_pwd';
CREATE DATABASE keto OWNER keto;
EOF
)

    # Deploy PostgreSQL
    helm upgrade --install ory-postgres bitnami/postgresql \
        --namespace "$ORY_NAMESPACE" \
        -f "$PROJECT_ROOT/helm/values/values-postgres.yaml" \
        --set-string "primary.initdb.scripts.init\.sql=$init_sql" \
        --wait --timeout=5m

    # Get postgres password from Bitnami secret
    local postgres_pwd=$(kubectl get secret --namespace "$ORY_NAMESPACE" ory-postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

    # Build DSNs (correct host for Bitnami)
    local host="ory-postgres-postgresql.$ORY_NAMESPACE.svc.cluster.local"
    local kratos_dsn="postgres://kratos:$kratos_pwd@$host:5432/kratos?sslmode=disable"
    local keto_dsn="postgres://keto:$keto_pwd@$host:5432/keto?sslmode=disable"

    # Create secrets
    kubectl create secret generic kratos-db-credentials \
        --namespace "$ORY_NAMESPACE" \
        --from-literal=dsn="$kratos_dsn" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic keto-db-credentials \
        --namespace "$ORY_NAMESPACE" \
        --from-literal=dsn="$keto_dsn" --dry-run=client -o yaml | kubectl apply -f -

    log_info "PostgreSQL deployed and DSN secrets created"
}

# Generate secure random secrets
generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
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
    
    # Get SMTP URI from secret if it exists
    local smtp_uri=""
    if kubectl get secret kratos-smtp-credentials -n "$ORY_NAMESPACE" &>/dev/null; then
        smtp_uri=$(kubectl get secret kratos-smtp-credentials -n "$ORY_NAMESPACE" -o jsonpath='{.data.connection_uri}' | base64 -d)
        log_info "Found SMTP credentials secret"
    else
        log_warn "SMTP secret 'kratos-smtp-credentials' not found in namespace '$ORY_NAMESPACE'"
        log_warn "Email delivery will not work. Create secret with:"
        log_warn "  kubectl create secret generic kratos-smtp-credentials \\"
        log_warn "    --namespace $ORY_NAMESPACE \\"
        log_warn "    --from-literal=connection_uri='smtps://user:pass@mail.infomaniak.com:465'"
    fi
    
    local helm_args=(
        --namespace "$ORY_NAMESPACE"
        -f "$PROJECT_ROOT/helm/values/values-kratos.yaml"
        --set kratos.config.dsn="$dsn"
        --set kratos.config.secrets.cookie[0]="$cookie_secret"
        --set kratos.config.secrets.cipher[0]="$cipher_secret"
        --wait --timeout=5m
    )
    
    # Add SMTP URI if available
    if [[ -n "$smtp_uri" ]]; then
        helm_args+=(--set-string "kratos.config.courier.smtp.connection_uri=$smtp_uri")
    fi
    
    helm upgrade --install kratos ory/kratos "${helm_args[@]}"
    
    log_info "Kratos deployed"
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

if [[ $# -gt 0 ]]; then 
    "$@"
fi