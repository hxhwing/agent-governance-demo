#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_config.sh"

TOKEN=$(gcloud auth print-access-token --quiet)
TMP_PAYLOAD="$(mktemp)"
trap 'rm -f "${TMP_PAYLOAD}"' EXIT

register_endpoint() {
  local SERVICE_ID="$1"
  local PAYLOAD_FILE="$2"
  echo "Registering Endpoint Service ${SERVICE_ID} in Agent Registry (${PROJECT_ID}/${LOCATION})..."
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

discord_payload = {
    "displayName": "Discord Community Bot Webhook",
    "description": "已备案官方 Discord 玩家社区状态频道公告机器人 Webhook 外部接口",
    "endpointSpec": {"type": "NO_SPEC"},
    "interfaces": [
        {"url": "https://httpbin.org", "protocolBinding": "HTTP_JSON"},
        {"url": "https://httpbin.org/post", "protocolBinding": "HTTP_JSON"}
    ]
}

with open("${TMP_PAYLOAD}", "w") as f:
    json.dump(discord_payload, f, indent=2, ensure_ascii=False)
PYEOF

register_endpoint "discord-community-webhook" "${TMP_PAYLOAD}"

echo "=== Verifying Registered Endpoints in Agent Registry (${LOCATION}) ==="
curl -s -H "Authorization: Bearer ${TOKEN}" \
  "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${LOCATION}/endpoints" | python3 -m json.tool
