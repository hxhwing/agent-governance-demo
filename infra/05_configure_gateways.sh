#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_config.sh"

INGRESS_GW="${INGRESS_GATEWAY_NAME}"
EGRESS_GW="${EGRESS_GATEWAY_NAME}"
MA_TEMPLATE="projects/${PROJECT_ID}/locations/${LOCATION}/templates/${MODEL_ARMOR_TEMPLATE_ID}"
MODE="${1:-enforce}"

TOKEN=$(gcloud auth print-access-token --quiet)

# Dynamically grant Model Armor roles to both Ingress & Egress Gateway tenant Service Extensions SAs
for GW_NAME in "${INGRESS_GW}" "${EGRESS_GW}"; do
  TENANT_DEP_SA=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${GW_NAME}" \
    | python3 -c "import sys, json; print(json.load(sys.stdin).get('agentGatewayCard',{}).get('serviceExtensionsServiceAccount',''))" 2>/dev/null || true)

  if [ -n "${TENANT_DEP_SA}" ]; then
    echo "Granting Model Armor roles to ${GW_NAME} Tenant SA: ${TENANT_DEP_SA}"
    for ROLE in "roles/modelarmor.calloutUser" "roles/modelarmor.user" "roles/serviceusage.serviceUsageConsumer"; do
      gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${TENANT_DEP_SA}" \
        --role="${ROLE}" \
        --condition=None \
        --quiet >/dev/null || true
    done
  fi
done

upsert_extension() {
  local EXT_ID="$1"
  local BODY="$2"
  local CODE
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
    "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzExtensions/${EXT_ID}")
  if [ "${CODE}" = "200" ]; then
    echo "Updating authzExtension ${EXT_ID}..."
    curl -s -X PATCH \
      "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzExtensions/${EXT_ID}?updateMask=metadata,failOpen,timeout" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${BODY}" | python3 -m json.tool
  else
    echo "Creating authzExtension ${EXT_ID}..."
    curl -s -X POST \
      "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzExtensions?authzExtensionId=${EXT_ID}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${BODY}" | python3 -m json.tool
  fi
  sleep 8
}

upsert_policy() {
  local POL_ID="$1"
  local BODY="$2"
  local CODE
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
    "https://networksecurity.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzPolicies/${POL_ID}")
  if [ "${CODE}" = "200" ]; then
    echo "Updating authzPolicy ${POL_ID}..."
    curl -s -X PATCH \
      "https://networksecurity.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzPolicies/${POL_ID}?updateMask=httpRules,customProvider" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${BODY}" | python3 -m json.tool
  else
    echo "Creating authzPolicy ${POL_ID}..."
    curl -s -X POST \
      "https://networksecurity.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${LOCATION}/authzPolicies?authzPolicyId=${POL_ID}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${BODY}" | python3 -m json.tool
  fi
  sleep 8
}

echo "=== 1. Configuring Model Armor (CONTENT_AUTHZ) on Ingress Gateway (${INGRESS_GW}) ==="
MA_SETTINGS_JSON="[{\"request_template_id\":\"${MA_TEMPLATE}\",\"response_template_id\":\"${MA_TEMPLATE}\"}]"

upsert_extension "ingress-gw-ma-ext" "{
  \"service\": \"modelarmor.${LOCATION}.rep.googleapis.com\",
  \"failOpen\": false,
  \"timeout\": \"5s\",
  \"metadata\": {
    \"model_armor_settings\": $(python3 -c "import json; print(json.dumps('${MA_SETTINGS_JSON}'))")
  }
}"

upsert_policy "ingress-gw-ma-policy" "{
  \"target\": {
    \"loadBalancingScheme\": \"LOAD_BALANCING_SCHEME_UNSPECIFIED\",
    \"resources\": [\"projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${INGRESS_GW}\"]
  },
  \"action\": \"CUSTOM\",
  \"policyProfile\": \"CONTENT_AUTHZ\",
  \"httpRules\": [{
    \"to\": {
      \"operations\": [{\"paths\": [{\"prefix\": \"/\"}]}]
    }
  }],
  \"customProvider\": {
    \"authzExtension\": {
      \"resources\": [\"projects/${PROJECT_ID}/locations/${LOCATION}/authzExtensions/ingress-gw-ma-ext\"]
    }
  }
}"

echo "=== 2. Configuring IAP / IAM UAP (REQUEST_AUTHZ) on Egress Gateway (${EGRESS_GW}, mode=${MODE}) ==="
if [ "${MODE}" = "enforce" ]; then
  IAP_META='{"iapPolicyVersion": "V2"}'
else
  IAP_META='{"iapPolicyVersion": "V2", "iamEnforcementMode": "DRY_RUN"}'
fi

upsert_extension "liveops-egress-iap-ext" "{
  \"service\": \"iap.googleapis.com\",
  \"failOpen\": false,
  \"timeout\": \"5s\",
  \"metadata\": ${IAP_META}
}"

upsert_policy "liveops-egress-iap-policy" "{
  \"target\": {
    \"loadBalancingScheme\": \"LOAD_BALANCING_SCHEME_UNSPECIFIED\",
    \"resources\": [\"projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${EGRESS_GW}\"]
  },
  \"action\": \"CUSTOM\",
  \"policyProfile\": \"REQUEST_AUTHZ\",
  \"httpRules\": [{
    \"to\": {
      \"operations\": [{\"paths\": [{\"prefix\": \"/\"}]}]
    }
  }],
  \"customProvider\": {
    \"authzExtension\": {
      \"resources\": [\"projects/${PROJECT_ID}/locations/${LOCATION}/authzExtensions/liveops-egress-iap-ext\"]
    }
  }
}"

echo "=== 3. Configuring Model Armor (CONTENT_AUTHZ) on Egress Gateway (${EGRESS_GW}) ==="
upsert_extension "liveops-egress-ma-ext" "{
  \"service\": \"modelarmor.${LOCATION}.rep.googleapis.com\",
  \"failOpen\": false,
  \"timeout\": \"5s\",
  \"metadata\": {
    \"model_armor_settings\": $(python3 -c "import json; print(json.dumps('${MA_SETTINGS_JSON}'))")
  }
}"

upsert_policy "liveops-egress-ma-policy" "{
  \"target\": {
    \"loadBalancingScheme\": \"LOAD_BALANCING_SCHEME_UNSPECIFIED\",
    \"resources\": [\"projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${EGRESS_GW}\"]
  },
  \"action\": \"CUSTOM\",
  \"policyProfile\": \"CONTENT_AUTHZ\",
  \"httpRules\": [{
    \"to\": {
      \"operations\": [{\"paths\": [{\"prefix\": \"/\"}]}]
    }
  }],
  \"customProvider\": {
    \"authzExtension\": {
      \"resources\": [\"projects/${PROJECT_ID}/locations/${LOCATION}/authzExtensions/liveops-egress-ma-ext\"]
    }
  }
}"

echo "=== Gateway Policy Configuration Complete (mode=${MODE}) ==="
