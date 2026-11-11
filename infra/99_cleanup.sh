#!/usr/bin/env bash
# ==============================================================================
# Teardown & Cost-Saving Cleanup Script for Agent Security & Governance Demo
# Deletes billable compute/gateway resources in strict reverse dependency order:
#   1. Gemini Enterprise agent registration (if configured)
#   2. Semantic Governance Policies & SGP Engine gateway detachment
#   3. Gemini Agent Runtime (ReasoningEngine)
#   4. Network Security AuthzPolicies & Network Services AuthzExtensions
#   5. Ingress & Egress Agent Gateways (managed Envoy / SWP instances)
#   6. AgentConnectivityTemplate, PSC Network Attachment & Private Cloud DNS Zone
#   7. Cloud Run services (including min-instances=1 MCP server)
#   8. Agent Registry services, IAM v3beta UAP binding/policy & Model Armor template
#   9. (Optional --purge-storage) Artifact Registry repo & GCS staging bucket
#
# Usage:
#   ./infra/99_cleanup.sh                  # Interactive confirmation
#   ./infra/99_cleanup.sh --yes            # Non-interactive cleanup
#   ./infra/99_cleanup.sh --yes --purge-storage  # Also delete Docker repo & GCS bucket
# ==============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_config.sh"

AUTO_YES=false
PURGE_STORAGE=false
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) AUTO_YES=true ;;
    --purge-storage) PURGE_STORAGE=true ;;
    -h|--help)
      echo "Usage: $0 [--yes|-y] [--purge-storage]"
      exit 0
      ;;
  esac
done

DNS_ZONE_NAME="${DNS_ZONE_NAME:-sgp-private-zone}"
NET_ATTACHMENT_NAME="${NET_ATTACHMENT_NAME:-sgp-nw-attachment}"
CONN_TEMPLATE_NAME="${CONN_TEMPLATE_NAME:-sgp-connectivity-template}"
STAGING_BUCKET="${STAGING_BUCKET:-gs://${PROJECT_ID}-agent-gov-staging}"

echo "======================================================================"
echo " Google Cloud Agent Security & Governance — Resource Cleanup"
echo "======================================================================"
echo "  Project ID          : ${PROJECT_ID} (${PROJECT_NUMBER:-unknown})"
echo "  Region              : ${LOCATION}"
echo "  Gateways            : ${INGRESS_GATEWAY_NAME}, ${EGRESS_GATEWAY_NAME}"
echo "  Cloud Run Services  : game-liveops-mcp, sre-incident-a2a-agent, billing-refund-a2a-agent"
echo "  Purge Storage       : ${PURGE_STORAGE} (${ARTIFACT_REPO_NAME}, ${STAGING_BUCKET})"
echo "======================================================================"

if [[ "${AUTO_YES}" != "true" ]]; then
  read -r -p "Confirm deleting the demo resources above in project '${PROJECT_ID}'? [y/N] " reply
  if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
  fi
fi

refresh_token() {
  TOKEN="$(gcloud auth print-access-token --quiet)"
}
refresh_token

wait_until_404() {
  local url="$1"
  local label="$2"
  local max_attempts="${3:-36}"
  local sleep_sec="${4:-10}"
  for ((i=1; i<=max_attempts; i++)); do
    refresh_token
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${url}" || true)
    if [[ "${code}" == "404" ]]; then
      echo "  [OK] ${label} deleted."
      return 0
    fi
    echo "  ... waiting for ${label} deletion (${i}/${max_attempts}, HTTP ${code})..."
    sleep "${sleep_sec}"
  done
  echo "  [WARN] Timed out waiting for ${label} deletion; continuing..."
}

delete_if_exists() {
  local url="$1"
  local label="$2"
  refresh_token
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "${url}" || true)
  if [[ "${code}" == "200" ]]; then
    echo "  Deleting ${label}..."
    curl -s -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "x-goog-user-project: ${PROJECT_ID}" \
      "${url}" >/dev/null || true
    return 0
  else
    echo "  [SKIP] ${label} not found (HTTP ${code})."
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 1. Gemini Enterprise Registration (Optional)
# ------------------------------------------------------------------------------
echo ""
echo "=== 1. Removing Gemini Enterprise Agent Registration ==="
if [[ -n "${GEMINI_ENTERPRISE_APP_ID:-}" ]]; then
  GE_BASE="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/global/collections/default_collection/engines/${GEMINI_ENTERPRISE_APP_ID}/assistants/default_assistant/agents"
  GE_AGENT_NAME=$(curl -s -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT_ID}" "${GE_BASE}" \
    | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin).get('agents', []):
        if a.get('displayName') == 'Game LiveOps Governance Orchestrator':
            print(a.get('name', '')); break
except Exception:
    pass
" || true)
  if [[ -n "${GE_AGENT_NAME}" ]]; then
    echo "  Deleting Gemini Enterprise agent: ${GE_AGENT_NAME}"
    curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
      -H "x-goog-user-project: ${PROJECT_ID}" \
      "https://discoveryengine.googleapis.com/v1alpha/${GE_AGENT_NAME}" >/dev/null || true
  else
    echo "  [SKIP] No matching Gemini Enterprise agent registration found."
  fi
else
  echo "  [SKIP] GEMINI_ENTERPRISE_APP_ID not set."
fi

# ------------------------------------------------------------------------------
# 2. Semantic Governance Policies & SGP Engine Gateway Config
# ------------------------------------------------------------------------------
echo ""
echo "=== 2. Cleaning Up Semantic Governance Policies & Detaching SGP Engine ==="
SGP_LIST_URL="https://${LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/semanticGovernancePolicies"
SGP_NAMES=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${SGP_LIST_URL}" \
  | python3 -c "
import sys, json
try:
    for p in json.load(sys.stdin).get('semanticGovernancePolicies', []):
        n = p.get('name', '')
        if 'liveops-' in n or '${SGP_POLICY_ID}' in n:
            print(n)
except Exception:
    pass
" || true)

if [[ -n "${SGP_NAMES}" ]]; then
  while IFS= read -r pol_name; do
    [[ -z "${pol_name}" ]] && continue
    echo "  Deleting SGP policy: ${pol_name}"
    curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
      "https://${LOCATION}-aiplatform.googleapis.com/v1beta1/${pol_name}" >/dev/null || true
  done <<< "${SGP_NAMES}"
else
  echo "  [SKIP] No active Semantic Governance Policies found."
fi

echo "  Detaching gatewayConfigs from Semantic Governance Policy Engine..."
curl -s -X PATCH \
  "https://${LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/semanticGovernancePolicyEngine?updateMask=gatewayConfigs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"gatewayConfigs": {}}' >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 3. Gemini Agent Runtime (ReasoningEngine — Major Hourly Cost)
# ------------------------------------------------------------------------------
echo ""
echo "=== 3. Deleting Gemini Agent Runtime (game-liveops-orchestrator) ==="
ENGINE_IDS=()
if [[ -n "${ORCHESTRATOR_ENGINE_ID:-}" ]]; then
  ENGINE_IDS+=("${ORCHESTRATOR_ENGINE_ID}")
fi

DISCOVERED_IDS=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "https://${LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
  | python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin).get('reasoningEngines', []):
        if r.get('displayName') == 'game-liveops-orchestrator':
            print(r['name'].split('/')[-1])
except Exception:
    pass
" || true)

if [[ -n "${DISCOVERED_IDS}" ]]; then
  while IFS= read -r eid; do
    [[ -z "${eid}" ]] && continue
    if [[ ! " ${ENGINE_IDS[*]:-} " =~ " ${eid} " ]]; then
      ENGINE_IDS+=("${eid}")
    fi
  done <<< "${DISCOVERED_IDS}"
fi

if [[ ${#ENGINE_IDS[@]} -gt 0 ]]; then
  for eid in "${ENGINE_IDS[@]}"; do
    RE_URL="https://${LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines/${eid}"
    echo "  Deleting ReasoningEngine ${eid} (force=true)..."
    curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" "${RE_URL}?force=true" >/dev/null || true
    wait_until_404 "${RE_URL}" "ReasoningEngine ${eid}" 30 8
  done
else
  echo "  [SKIP] No game-liveops-orchestrator ReasoningEngine found."
fi

# ------------------------------------------------------------------------------
# 4. Gateway AuthzPolicies & AuthzExtensions
# ------------------------------------------------------------------------------
echo ""
echo "=== 4. Deleting Gateway AuthzPolicies & AuthzExtensions ==="
for POL_ID in "ingress-gw-ma-policy" "liveops-egress-iap-policy" "liveops-egress-ma-policy"; do
  POL_URL="https://networksecurity.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzPolicies/${POL_ID}"
  if delete_if_exists "${POL_URL}" "AuthzPolicy ${POL_ID}"; then
    wait_until_404 "${POL_URL}" "AuthzPolicy ${POL_ID}" 18 5
  fi
done

for EXT_ID in "ingress-gw-ma-ext" "liveops-egress-iap-ext" "liveops-egress-ma-ext"; do
  EXT_URL="https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzExtensions/${EXT_ID}"
  if delete_if_exists "${EXT_URL}" "AuthzExtension ${EXT_ID}"; then
    wait_until_404 "${EXT_URL}" "AuthzExtension ${EXT_ID}" 18 5
  fi
done

# ------------------------------------------------------------------------------
# 5. Ingress & Egress Agent Gateways (Managed Envoy / SWP — Major Hourly Cost)
# ------------------------------------------------------------------------------
echo ""
echo "=== 5. Deleting Ingress & Egress Agent Gateways ==="
for GW_NAME in "${INGRESS_GATEWAY_NAME}" "${EGRESS_GATEWAY_NAME}"; do
  GW_URL="https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${GW_NAME}"
  if delete_if_exists "${GW_URL}" "AgentGateway ${GW_NAME}"; then
    wait_until_404 "${GW_URL}" "AgentGateway ${GW_NAME}" 36 10
  fi
done

# ------------------------------------------------------------------------------
# 6. AgentConnectivityTemplate, PSC Network Attachment & Private DNS Zone
# ------------------------------------------------------------------------------
echo ""
echo "=== 6. Deleting Connectivity Template, PSC Network Attachment & Private DNS ==="
CT_URL="https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentConnectivityTemplates/${CONN_TEMPLATE_NAME}"
if delete_if_exists "${CT_URL}" "AgentConnectivityTemplate ${CONN_TEMPLATE_NAME}"; then
  wait_until_404 "${CT_URL}" "AgentConnectivityTemplate ${CONN_TEMPLATE_NAME}" 24 8
fi

if gcloud compute network-attachments describe "${NET_ATTACHMENT_NAME}" --region="${LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "  Deleting PSC Network Attachment: ${NET_ATTACHMENT_NAME}..."
  gcloud compute network-attachments delete "${NET_ATTACHMENT_NAME}" \
    --region="${LOCATION}" \
    --project="${PROJECT_ID}" \
    --quiet || true
else
  echo "  [SKIP] Network attachment ${NET_ATTACHMENT_NAME} not found."
fi

if gcloud dns managed-zones describe "${DNS_ZONE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "  Deleting Private Cloud DNS Zone: ${DNS_ZONE_NAME}..."
  # Remove any non-NS/SOA records first so managed-zones delete succeeds cleanly
  gcloud dns record-sets list --zone="${DNS_ZONE_NAME}" --project="${PROJECT_ID}" --format=json 2>/dev/null \
    | python3 -c "
import sys, json, subprocess
for r in json.load(sys.stdin):
    if r.get('type') not in ('NS', 'SOA'):
        subprocess.run([
            'gcloud', 'dns', 'record-sets', 'delete', r['name'],
            '--type=' + r['type'],
            '--zone=${DNS_ZONE_NAME}',
            '--project=${PROJECT_ID}',
            '--quiet'
        ], check=False)
" || true
  gcloud dns managed-zones delete "${DNS_ZONE_NAME}" --project="${PROJECT_ID}" --quiet || true
else
  echo "  [SKIP] DNS zone ${DNS_ZONE_NAME} not found."
fi

# ------------------------------------------------------------------------------
# 7. Cloud Run Backend Services (including min-instances=1 MCP server)
# ------------------------------------------------------------------------------
echo ""
echo "=== 7. Deleting Cloud Run Services ==="
for SVC in "game-liveops-mcp" "sre-incident-a2a-agent" "billing-refund-a2a-agent"; do
  if gcloud run services describe "${SVC}" --region="${LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "  Deleting Cloud Run service: ${SVC}..."
    gcloud run services delete "${SVC}" --region="${LOCATION}" --project="${PROJECT_ID}" --quiet || true
  else
    echo "  [SKIP] Cloud Run service ${SVC} not found."
  fi
done

# ------------------------------------------------------------------------------
# 8. Agent Registry Services, IAM UAP Binding/Policy & Model Armor Template
# ------------------------------------------------------------------------------
echo ""
echo "=== 8. Cleaning Up Agent Registry, IAM UAP Policy & Model Armor Template ==="
for REG_SVC in "game-liveops-mcp" "sre-incident-a2a-agent" "billing-refund-a2a-agent" "discord-community-webhook"; do
  REG_URL="https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${LOCATION}/services/${REG_SVC}"
  delete_if_exists "${REG_URL}" "Agent Registry Service ${REG_SVC}" || true
done

BINDING_URL="https://iam.googleapis.com/v3beta/projects/${PROJECT_ID}/locations/global/policyBindings/liveops-egress-uap-binding"
if delete_if_exists "${BINDING_URL}" "IAM UAP PolicyBinding liveops-egress-uap-binding"; then
  wait_until_404 "${BINDING_URL}" "IAM UAP PolicyBinding" 12 4
fi

UAP_URL="https://iam.googleapis.com/v3beta/projects/${PROJECT_ID}/locations/global/accessPolicies/${UAP_POLICY_ID}"
delete_if_exists "${UAP_URL}" "IAM UAP AccessPolicy ${UAP_POLICY_ID}" || true

MA_URL="https://modelarmor.${LOCATION}.rep.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/templates/${MODEL_ARMOR_TEMPLATE_ID}"
delete_if_exists "${MA_URL}" "Model Armor Template ${MODEL_ARMOR_TEMPLATE_ID}" || true

# ------------------------------------------------------------------------------
# 9. Optional Storage Cleanup (--purge-storage) & Local .env Runtime Reset
# ------------------------------------------------------------------------------
echo ""
if [[ "${PURGE_STORAGE}" == "true" ]]; then
  echo "=== 9. Purging Artifact Registry Repository & GCS Staging Bucket ==="
  if gcloud artifacts repositories describe "${ARTIFACT_REPO_NAME}" --location="${LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "  Deleting Artifact Registry repository: ${ARTIFACT_REPO_NAME}..."
    gcloud artifacts repositories delete "${ARTIFACT_REPO_NAME}" \
      --location="${LOCATION}" \
      --project="${PROJECT_ID}" \
      --quiet || true
  fi
  if gcloud storage buckets describe "${STAGING_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "  Deleting GCS staging bucket: ${STAGING_BUCKET}..."
    gcloud storage rm --recursive "${STAGING_BUCKET}" --project="${PROJECT_ID}" --quiet || true
  fi
else
  echo "=== 9. Storage Artifacts Retained for Fast Redeploy ==="
  echo "  (Pass --purge-storage to also delete Artifact Registry '${ARTIFACT_REPO_NAME}' and '${STAGING_BUCKET}')"
fi

if [[ -f "${ENV_FILE}" ]]; then
  tmp_env="$(mktemp)"
  grep -v -E "^(MCP_URL|SRE_URL|BILLING_URL|ORCHESTRATOR_ENGINE_ID|ORCHESTRATOR_RESOURCE_NAME|ORCHESTRATOR_SPIFFE_ID)=" "${ENV_FILE}" > "${tmp_env}" || true
  mv "${tmp_env}" "${ENV_FILE}"
  echo "  Cleared runtime deployment IDs from local .env (kept PROJECT_ID / REGION settings)."
fi

echo ""
echo "=== Cleanup Complete: All billable compute & gateway instances have been removed! ==="
