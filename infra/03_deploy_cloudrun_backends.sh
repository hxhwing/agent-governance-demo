#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_config.sh"

IMAGE_URI="${LOCATION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO_NAME}/liveops-backend:latest"
SRC_DIR="${ROOT_DIR}/services/cloudrun_mcp_and_a2a"
TMP_SPECS_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_SPECS_DIR}"' EXIT

echo "=== 0. Ensuring Artifact Registry Repository (${ARTIFACT_REPO_NAME}) & Cloud Run IAM ==="
if ! gcloud artifacts repositories describe "${ARTIFACT_REPO_NAME}" --location="${LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${ARTIFACT_REPO_NAME}" \
    --repository-format=docker \
    --location="${LOCATION}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

for ROLE in "roles/aiplatform.user" "roles/modelarmor.user"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null || true
done

echo "=== 1. Building Container Image via Cloud Build: ${IMAGE_URI} ==="
gcloud builds submit "${SRC_DIR}" \
  --tag="${IMAGE_URI}" \
  --project="${PROJECT_ID}" \
  --quiet

echo "=== 2. Deploying Cloud Run Services (game-liveops-mcp + sre-incident-a2a-agent + billing-refund-a2a-agent) ==="
gcloud run deploy "game-liveops-mcp" \
  --image="${IMAGE_URI}" \
  --region="${LOCATION}" \
  --platform=managed \
  --allow-unauthenticated \
  --min-instances=1 \
  --max-instances=1 \
  --set-env-vars="SERVICE_ROLE=mcp,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},LOCATION=${LOCATION},MODEL_LOCATION=${MODEL_LOCATION},MODEL_NAME=${MODEL_NAME},MODEL_ARMOR_TEMPLATE_ID=${MODEL_ARMOR_TEMPLATE_ID},SGP_POLICY_ID=${SGP_POLICY_ID}" \
  --project="${PROJECT_ID}" \
  --quiet

for SVC_PAIR in "sre-incident-a2a-agent:sre" "billing-refund-a2a-agent:billing"; do
  SVC_NAME="${SVC_PAIR%%:*}"
  SVC_ROLE="${SVC_PAIR##*:}"
  echo "Deploying ${SVC_NAME} (role=${SVC_ROLE})..."
  gcloud run deploy "${SVC_NAME}" \
    --image="${IMAGE_URI}" \
    --region="${LOCATION}" \
    --platform=managed \
    --allow-unauthenticated \
    --set-env-vars="SERVICE_ROLE=${SVC_ROLE},GOOGLE_CLOUD_PROJECT=${PROJECT_ID},LOCATION=${LOCATION},MODEL_LOCATION=${MODEL_LOCATION},MODEL_NAME=${MODEL_NAME}" \
    --project="${PROJECT_ID}" \
    --quiet
done

MCP_URL=$(gcloud run services describe game-liveops-mcp --region="${LOCATION}" --project="${PROJECT_ID}" --format="value(status.url)")
SRE_URL=$(gcloud run services describe sre-incident-a2a-agent --region="${LOCATION}" --project="${PROJECT_ID}" --format="value(status.url)")
BILLING_URL=$(gcloud run services describe billing-refund-a2a-agent --region="${LOCATION}" --project="${PROJECT_ID}" --format="value(status.url)")

echo "MCP_URL=${MCP_URL}"
echo "SRE_URL=${SRE_URL}"
echo "BILLING_URL=${BILLING_URL}"

upsert_env_var "MCP_URL" "${MCP_URL}"
upsert_env_var "SRE_URL" "${SRE_URL}"
upsert_env_var "BILLING_URL" "${BILLING_URL}"

echo "=== 3. Fetching Live Specs & Registering in Agent Registry (${LOCATION}) ==="
TOKEN=$(gcloud auth print-access-token --quiet)

curl -s -X POST "${MCP_URL}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}' \
  | python3 -c "import sys, json; d=json.load(sys.stdin); print(json.dumps(d['result'], indent=2, ensure_ascii=False))" > "${TMP_SPECS_DIR}/mcp_tool_spec.json"

curl -s "${SRE_URL}/.well-known/agent-card.json" | python3 -m json.tool > "${TMP_SPECS_DIR}/sre_agent_card.json"
curl -s "${BILLING_URL}/.well-known/agent-card.json" | python3 -m json.tool > "${TMP_SPECS_DIR}/billing_agent_card.json"

register_service() {
  local SERVICE_ID="$1"
  local PAYLOAD_FILE="$2"
  echo "Registering ${SERVICE_ID} in Agent Registry..."
  local HTTP_CODE
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${LOCATION}/services/${SERVICE_ID}")
  if [ "${HTTP_CODE}" = "200" ]; then
    curl -s -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${LOCATION}/services/${SERVICE_ID}" >/dev/null
    sleep 3
  fi
  curl -s -X POST \
    "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${LOCATION}/services?serviceId=${SERVICE_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"${PAYLOAD_FILE}" | python3 -m json.tool
  sleep 3
}

python3 - <<PYEOF
import json

with open("${TMP_SPECS_DIR}/mcp_tool_spec.json") as f:
    mcp_spec = json.load(f)

mcp_service_payload = {
    "displayName": "Game LiveOps MCP Server",
    "description": "游戏客服与 GM 管理 MCP 服务：工单只读查询 (query_player_ticket)、金币补偿发放 (grant_player_compensation)、以及高危账号封禁 (ban_player_account)",
    "interfaces": [{"url": "${MCP_URL}/mcp", "protocolBinding": "JSONRPC"}],
    "mcpServerSpec": {"type": "TOOL_SPEC", "content": mcp_spec}
}
with open("${TMP_SPECS_DIR}/reg_mcp.json", "w") as f:
    json.dump(mcp_service_payload, f, indent=2, ensure_ascii=False)

with open("${TMP_SPECS_DIR}/sre_agent_card.json") as f:
    sre_card = json.load(f)
sre_service_payload = {
    "displayName": "SRE Incident Diagnostics A2A Agent",
    "description": "已授权跨部门协作：SRE 运维故障诊断专员 Agent（综合内部节点告警与变更单研判服务器客观故障，不暴露底层监控工具）",
    "agentSpec": {"type": "A2A_AGENT_CARD", "content": sre_card}
}
with open("${TMP_SPECS_DIR}/reg_sre.json", "w") as f:
    json.dump(sre_service_payload, f, indent=2, ensure_ascii=False)

with open("${TMP_SPECS_DIR}/billing_agent_card.json") as f:
    bl_card = json.load(f)
bl_service_payload = {
    "displayName": "Billing Cash Refund A2A Agent",
    "description": "受限财务结算域：支付法币原路退费专员 Agent（负责微信支付/Apple Pay/信用卡原路退款，一线客服禁止越权调用）",
    "agentSpec": {"type": "A2A_AGENT_CARD", "content": bl_card}
}
with open("${TMP_SPECS_DIR}/reg_billing.json", "w") as f:
    json.dump(bl_service_payload, f, indent=2, ensure_ascii=False)
PYEOF

register_service "game-liveops-mcp" "${TMP_SPECS_DIR}/reg_mcp.json"
register_service "sre-incident-a2a-agent" "${TMP_SPECS_DIR}/reg_sre.json"
register_service "billing-refund-a2a-agent" "${TMP_SPECS_DIR}/reg_billing.json"
