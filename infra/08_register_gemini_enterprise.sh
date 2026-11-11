#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_config.sh"

GEMINI_ENTERPRISE_APP_ID="${GEMINI_ENTERPRISE_APP_ID:-}"
ORCHESTRATOR_RESOURCE_NAME="${ORCHESTRATOR_RESOURCE_NAME:-}"

if [[ -z "${GEMINI_ENTERPRISE_APP_ID}" ]]; then
  echo "ERROR: GEMINI_ENTERPRISE_APP_ID is required (set in .env or environment)." >&2
  exit 1
fi

if [[ -z "${ORCHESTRATOR_RESOURCE_NAME}" ]]; then
  echo "ERROR: ORCHESTRATOR_RESOURCE_NAME not found in .env or environment (run infra/06 first)." >&2
  exit 1
fi

TOKEN=$(gcloud auth print-access-token --quiet)
TMP_GE_JSON="$(mktemp)"
trap 'rm -f "${TMP_GE_JSON}"' EXIT

echo "=== Registering ${ORCHESTRATOR_RESOURCE_NAME} to Gemini Enterprise (${GEMINI_ENTERPRISE_APP_ID}) ==="

BASE_URL="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/global/collections/default_collection/engines/${GEMINI_ENTERPRISE_APP_ID}/assistants/default_assistant/agents"

EXISTING_AGENTS=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "${BASE_URL}")

EXISTING_AGENT_NAME=$(echo "${EXISTING_AGENTS}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('agents', []):
    if a.get('displayName') == 'Game LiveOps Governance Orchestrator':
        print(a.get('name', ''))
        break
")

if [[ -n "${EXISTING_AGENT_NAME}" ]]; then
  echo "Deleting previous registration ${EXISTING_AGENT_NAME}..."
  curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://discoveryengine.googleapis.com/v1alpha/${EXISTING_AGENT_NAME}" || true
fi

cat <<EOF > "${TMP_GE_JSON}"
{
  "displayName": "Game LiveOps Governance Orchestrator",
  "description": "Enterprise Game LiveOps Customer Support & Governance Orchestrator Agent protected by Agent Gateway, Model Armor, IAM UAP, and Semantic Governance Policy",
  "adkAgentDefinition": {
    "toolSettings": {
      "toolDescription": "Use this agent to investigate player tickets, collaborate with SRE incident diagnostics via A2A, issue governed player compensation via MCP, and inspect SPIFFE Agent Identity & Agent Registry governance policies."
    },
    "provisionedReasoningEngine": {
      "reasoningEngine": "${ORCHESTRATOR_RESOURCE_NAME}"
    }
  }
}
EOF

RESP=$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "${BASE_URL}" \
  -d @"${TMP_GE_JSON}")

echo "${RESP}" | python3 -m json.tool
