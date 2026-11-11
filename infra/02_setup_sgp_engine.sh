#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_config.sh"

DNS_ZONE_NAME="${DNS_ZONE_NAME:-sgp-private-zone}"
DNS_DOMAIN="${DNS_DOMAIN:-sgp.internal.}"
NET_ATTACHMENT_NAME="${NET_ATTACHMENT_NAME:-sgp-nw-attachment}"
CONN_TEMPLATE_NAME="${CONN_TEMPLATE_NAME:-sgp-connectivity-template}"
INGRESS_GW_NAME="${INGRESS_GATEWAY_NAME}"
EGRESS_GW_NAME="${EGRESS_GATEWAY_NAME}"

TOKEN=$(gcloud auth print-access-token --quiet)

echo "=== 1. Granting IAM roles to Vertex AI & Agent Gateway Service Agents (${PROJECT_ID}) ==="
gcloud beta services identity create --service=aiplatform.googleapis.com --project="${PROJECT_ID}" --quiet || true
gcloud beta services identity create --service=networkservices.googleapis.com --project="${PROJECT_ID}" --quiet || true

for ROLE in "roles/compute.networkAdmin" "roles/dns.admin"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null || true
done

for ROLE in "roles/compute.networkAdmin" "roles/compute.networkViewer" "roles/dns.peer" "roles/dns.reader" "roles/dns.admin"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-agentgateway.iam.gserviceaccount.com" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null || true
done
sleep 10

echo "=== 2. Ensuring Private IP Google Access on ${SUBNET_NAME} (${NETWORK_NAME}) ==="
gcloud compute networks subnets update "${SUBNET_NAME}" \
  --region="${LOCATION}" \
  --enable-private-ip-google-access \
  --project="${PROJECT_ID}" \
  --quiet

echo "=== 3. Creating Private Cloud DNS Zone: ${DNS_ZONE_NAME} (${DNS_DOMAIN}) ==="
if ! gcloud dns managed-zones describe "${DNS_ZONE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud dns managed-zones create "${DNS_ZONE_NAME}" \
    --description="Private DNS zone for Semantic Governance Policy Engine" \
    --dns-name="${DNS_DOMAIN}" \
    --visibility="private" \
    --networks="${NETWORK_NAME}" \
    --project="${PROJECT_ID}"
else
  echo "DNS zone ${DNS_ZONE_NAME} already exists."
fi

echo "=== 4. Creating PSC Network Attachment: ${NET_ATTACHMENT_NAME} ==="
if ! gcloud compute network-attachments describe "${NET_ATTACHMENT_NAME}" --region="${LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute network-attachments create "${NET_ATTACHMENT_NAME}" \
    --region="${LOCATION}" \
    --subnets="${SUBNET_NAME}" \
    --connection-preference=ACCEPT_AUTOMATIC \
    --project="${PROJECT_ID}"
else
  echo "Network attachment ${NET_ATTACHMENT_NAME} already exists."
fi

echo "=== 5. Creating AgentConnectivityTemplate: ${CONN_TEMPLATE_NAME} ==="
EXISTING_CT=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentConnectivityTemplates/${CONN_TEMPLATE_NAME}")

if [ "${EXISTING_CT}" != "200" ]; then
  curl -s -X POST \
    "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentConnectivityTemplates?agentConnectivityTemplateId=${CONN_TEMPLATE_NAME}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"accessPath\": \"AGENT_TO_ANYWHERE\",
      \"deploymentModel\": \"CENTRALIZED\",
      \"egressNetworkConfig\": {
        \"networkAttachment\": \"projects/${PROJECT_NUMBER}/regions/${LOCATION}/networkAttachments/${NET_ATTACHMENT_NAME}\",
        \"dnsPeeringConfig\": {
          \"domains\": [\"${DNS_DOMAIN}\"],
          \"targetNetwork\": \"projects/${PROJECT_ID}/global/networks/${NETWORK_NAME}\"
        },
        \"vpcEgress\": \"PRIVATE_RANGES_ONLY\"
      }
    }" | python3 -m json.tool
  for _ in {1..12}; do
    sleep 5
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
      "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentConnectivityTemplates/${CONN_TEMPLATE_NAME}")
    if [ "${STATUS}" = "200" ]; then
      echo "AgentConnectivityTemplate ${CONN_TEMPLATE_NAME} is ready."
      break
    fi
  done
else
  echo "AgentConnectivityTemplate ${CONN_TEMPLATE_NAME} already exists."
fi

echo "=== 6. Ensuring Ingress & Egress Agent Gateways (${INGRESS_GW_NAME}, ${EGRESS_GW_NAME}) ==="
EXISTING_IGW=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${INGRESS_GW_NAME}")

if [ "${EXISTING_IGW}" != "200" ]; then
  curl -s -X POST \
    "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways?agentGatewayId=${INGRESS_GW_NAME}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"protocols\": [\"MCP\"],
      \"googleManaged\": {
        \"governedAccessPath\": \"CLIENT_TO_AGENT\"
      }
    }" | python3 -m json.tool
else
  echo "Ingress gateway ${INGRESS_GW_NAME} already exists."
fi

EXISTING_GW=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${EGRESS_GW_NAME}")

if [ "${EXISTING_GW}" != "200" ]; then
  curl -s -X POST \
    "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways?agentGatewayId=${EGRESS_GW_NAME}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"protocols\": [\"MCP\"],
      \"googleManaged\": {
        \"governedAccessPath\": \"AGENT_TO_ANYWHERE\"
      },
      \"agentConnectivityTemplate\": \"projects/${PROJECT_NUMBER}/locations/${LOCATION}/agentConnectivityTemplates/${CONN_TEMPLATE_NAME}\",
      \"registries\": [
        \"//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/${LOCATION}\"
      ]
    }" | python3 -m json.tool
  for _ in {1..12}; do
    sleep 5
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
      "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${EGRESS_GW_NAME}")
    if [ "${STATUS}" = "200" ]; then
      echo "Egress gateway ${EGRESS_GW_NAME} is ready."
      break
    fi
  done
else
  echo "Egress gateway ${EGRESS_GW_NAME} already exists."
fi

echo "=== 7. Triggering Semantic Governance Policy Engine Provisioning (if enabled in region) ==="
curl -s -X PATCH \
  "https://${LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/semanticGovernancePolicyEngine?updateMask=gatewayConfigs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"gatewayConfigs\": {
      \"${EGRESS_GW_NAME}\": {
        \"network\": \"projects/${PROJECT_ID}/global/networks/${NETWORK_NAME}\",
        \"subnetwork\": \"projects/${PROJECT_ID}/regions/${LOCATION}/subnetworks/${SUBNET_NAME}\",
        \"dnsZoneName\": \"${DNS_ZONE_NAME}\"
      }
    }
  }" | python3 -m json.tool || true
