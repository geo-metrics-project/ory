#!/bin/bash

KRATOS_URL="https://kratos.combaldieu.fr"
EMAIL="antoine@combaldieu.fr"
PASSWORD="simpletest123"

echo "[INFO] Starting API login flow..."
FLOW_JSON=$(curl -s "${KRATOS_URL}/self-service/login/api")
echo "[RESPONSE] Login flow response:"
echo "$FLOW_JSON"

FLOW_ID=$(echo "$FLOW_JSON" | jq -r '.id')
CSRF_TOKEN=$(echo "$FLOW_JSON" | jq -r '.ui.nodes[] | select(.attributes.name=="csrf_token") | .attributes.value')

echo "[INFO] Submitting credentials to Kratos..."
LOGIN_RESPONSE=$(curl -i -s -X POST "${KRATOS_URL}/self-service/login?flow=${FLOW_ID}" \
  -H "Content-Type: application/json" \
  -d "{\"method\":\"password\",\"csrf_token\":\"${CSRF_TOKEN}\",\"identifier\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")

echo "[RESPONSE] Login submit response:"
echo "$LOGIN_RESPONSE"

SESSION_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -i 'Set-Cookie' | grep -o 'ory_session_token=[^;]*' | head -n1)
echo "[INFO] ory_session_token: $SESSION_TOKEN"