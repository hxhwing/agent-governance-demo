#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_config.sh"

ORCHESTRATOR_SPIFFE_ID="${ORCHESTRATOR_SPIFFE_ID:-}"
if [[ -z "${ORG_ID}" || -z "${PROJECT_NUMBER}" ]]; then
  echo "ERROR: ORG_ID and PROJECT_NUMBER are required for SPIFFE principal IAM UAP configuration." >&2
  exit 1
fi

PRINCIPAL_SET="principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
TOKEN=$(gcloud auth print-access-token --quiet)
TMP_UAP_JSON="$(mktemp)"
TMP_BIND_JSON="$(mktemp)"
trap 'rm -f "${TMP_UAP_JSON}" "${TMP_BIND_JSON}"' EXIT

echo "=== 1. Finding Registered Targets in Agent Registry (${PROJECT_ID}/${REGION}) ==="
AGENTS_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${REGION}/agents")

ENDPOINTS_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${REGION}/endpoints")

MCP_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${REGION}/mcpServers")

ESSENTIAL_EP=$(echo "${ENDPOINTS_JSON}" | python3 -c "
import sys, json
for ep in json.load(sys.stdin).get('endpoints', []):
    if 'essential' in ep.get('displayName', '').lower() or 'essential-gcp-apis' in ep.get('endpointId', ''):
        print(ep['name'].split('/')[-1]); break
")

DISCORD_WEBHOOK_EP=$(echo "${ENDPOINTS_JSON}" | python3 -c "
import sys, json
for ep in json.load(sys.stdin).get('endpoints', []):
    if 'discord' in json.dumps(ep).lower() or 'webhook' in json.dumps(ep).lower():
        print(ep['name'].split('/')[-1]); break
")

SRE_AGENT_ID=$(echo "${AGENTS_JSON}" | python3 -c "
import sys, json
for a in json.load(sys.stdin).get('agents', []):
    if 'sre-incident' in json.dumps(a).lower() or 'sre incident' in json.dumps(a).lower():
        print(a['name'].split('/')[-1]); break
")

MCP_SERVER_ID=$(echo "${MCP_JSON}" | python3 -c "
import sys, json
for m in json.load(sys.stdin).get('mcpServers', []):
    if 'liveops' in m.get('displayName', '').lower():
        print(m['name'].split('/')[-1]); break
")

echo "  Essential GCP APIs Endpoint ID      : ${ESSENTIAL_EP}"
echo "  Discord Community Bot Webhook ID    : ${DISCORD_WEBHOOK_EP}"
echo "  SRE Incident Diagnostics Agent ID   : ${SRE_AGENT_ID}"
echo "  Game LiveOps MCP Server ID          : ${MCP_SERVER_ID}"
echo "  Allowed MCP Tools (Explicit List)   : query_player_ticket, grant_player_compensation"
echo "  All Other Tools / Agents / Domains  : Zero-Trust Default DENY"

echo "=== 2. Upserting IAM v3beta Unified Access Policy (${UAP_POLICY_ID}) ==="
PRINCIPALS_JSON="[\"${PRINCIPAL_SET}\"]"
if [[ -n "${ORCHESTRATOR_SPIFFE_ID}" ]]; then
  PRINCIPALS_JSON="[\"${ORCHESTRATOR_SPIFFE_ID}\", \"${PRINCIPAL_SET}\"]"
fi

cat <<EOF > "${TMP_UAP_JSON}"
{
  "displayName": "Game LiveOps Egress UAP Allowlist Policy",
  "details": {
    "rules": [
      {
        "description": "Zero-trust allowlist: Essential GCP APIs, Discord Webhook, SRE A2A Agent, and ONLY MCP tools [query_player_ticket, grant_player_compensation]. All else denied by default.",
        "effect": "ALLOW",
        "principals": ${PRINCIPALS_JSON},
        "operation": {
          "permissions": [
            "iap.googleapis.com/resources.egressViaIAP"
          ]
        },
        "conditions": {
          "iap.googleapis.com": {
            "title": "AllowExplicitLiveOpsTargetsAndToolList",
            "expression": "destination.agent_registry.endpoint.name == 'projects/${PROJECT_ID}/locations/${REGION}/endpoints/${ESSENTIAL_EP}' || destination.agent_registry.endpoint.name == 'projects/${PROJECT_ID}/locations/${REGION}/endpoints/${DISCORD_WEBHOOK_EP}' || destination.agent_registry.agent.name == 'projects/${PROJECT_ID}/locations/${REGION}/agents/${SRE_AGENT_ID}' || (destination.agent_registry.mcp_server.name == 'projects/${PROJECT_ID}/locations/${REGION}/mcpServers/${MCP_SERVER_ID}' && (destination.agent_registry.mcp_server.tool.name == 'query_player_ticket' || destination.agent_registry.mcp_server.tool.name == 'grant_player_compensation'))"
          }
        }
      }
    ]
  }
}
EOF

EXISTING_UAP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://iam.googleapis.com/v3beta/projects/${PROJECT_ID}/locations/global/accessPolicies/${UAP_POLICY_ID}")

if [[ "${EXISTING_UAP}" == "200" ]]; then
  curl -s -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://iam.googleapis.com/v3beta/projects/${PROJECT_ID}/locations/global/accessPolicies/${UAP_POLICY_ID}" \
    -d @"${TMP_UAP_JSON}" | python3 -m json.tool
else
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://iam.googleapis.com/v3beta/projects/${PROJECT_ID}/locations/global/accessPolicies?accessPolicyId=${UAP_POLICY_ID}" \
    -d @"${TMP_UAP_JSON}" | python3 -m json.tool
  sleep 8
  BINDING_ID="liveops-egress-uap-binding"
  cat <<EOF > "${TMP_BIND_JSON}"
{
  "policyKind": "ACCESS",
  "policy": "projects/${PROJECT_ID}/locations/global/accessPolicies/${UAP_POLICY_ID}",
  "target": {
    "principalSet": "//cloudresourcemanager.googleapis.com/projects/${PROJECT_NUMBER}"
  }
}
EOF
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://iam.googleapis.com/v3beta/projects/${PROJECT_ID}/locations/global/policyBindings?policyBindingId=${BINDING_ID}" \
    -d @"${TMP_BIND_JSON}" | python3 -m json.tool || true
fi
