#!/usr/bin/env bash
# Shared environment & gcloud auto-discovery helper for all deployment scripts.
# Precedence: Shell Environment Variables > .env file > gcloud CLI auto-detection > safe defaults.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ROOT_DIR}/.env"

# Load .env only for variables not already exported in the caller's shell environment
if [[ -f "${ENV_FILE}" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ -z "${!key+x}" ]]; then
        export "${key}=${val}"
      fi
    fi
  done < "${ENV_FILE}"
fi

export PROJECT_ID="${PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project 2>/dev/null | tr -d '\r' || true)}}"
if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" || "${PROJECT_ID}" == "your-gcp-project-id" ]]; then
  echo "ERROR: PROJECT_ID is required. Set it via environment variable (export PROJECT_ID=...) or in .env." >&2
  exit 1
fi

export PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null | tr -d '\r' || true)}"
export ORG_ID="${ORG_ID:-$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json 2>/dev/null | python3 -c "import sys,json; print(next((x['id'] for x in json.load(sys.stdin) if x.get('type')=='organization'), ''))" 2>/dev/null || true)}"

export REGION="${REGION:-${GOOGLE_CLOUD_LOCATION:-us-central1}}"
export LOCATION="${LOCATION:-${REGION}}"
export MODEL_LOCATION="${MODEL_LOCATION:-global}"
export MODEL_NAME="${MODEL_NAME:-gemini-3.8-flash}"

export NETWORK_NAME="${NETWORK_NAME:-default}"
export SUBNET_NAME="${SUBNET_NAME:-default}"
export ARTIFACT_REPO_NAME="${ARTIFACT_REPO_NAME:-agent-gov-repo}"
export INGRESS_GATEWAY_NAME="${INGRESS_GATEWAY_NAME:-ingress-gw}"
export EGRESS_GATEWAY_NAME="${EGRESS_GATEWAY_NAME:-liveops-egress-gw}"
export MODEL_ARMOR_TEMPLATE_ID="${MODEL_ARMOR_TEMPLATE_ID:-agent-gov-ma-template}"
export UAP_POLICY_ID="${UAP_POLICY_ID:-liveops-egress-uap-policy}"
export SGP_POLICY_ID="${SGP_POLICY_ID:-liveops-compensation-cap-policy}"

upsert_env_var() {
  local key="$1"
  local val="$2"
  touch "${ENV_FILE}"
  local tmp_file
  tmp_file="$(mktemp)"
  grep -v -E "^${key}=" "${ENV_FILE}" > "${tmp_file}" || true
  echo "${key}=${val}" >> "${tmp_file}"
  mv "${tmp_file}" "${ENV_FILE}"
}
