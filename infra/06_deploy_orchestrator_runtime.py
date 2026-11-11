#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))

from dotenv import load_dotenv
load_dotenv(ROOT_DIR / ".env", override=False)

import cloudpickle
import google.oauth2.credentials
import vertexai
from vertexai._genai import types as vtypes
import agents.game_liveops_orchestrator.agent as agent_module
from agents.game_liveops_orchestrator.agent import root_agent

cloudpickle.register_pickle_by_value(agent_module)


def _gcloud_value(args: list[str]) -> str:
    try:
        return subprocess.check_output(["gcloud", *args], stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""


PROJECT_ID = (
    os.environ.get("PROJECT_ID")
    or os.environ.get("GOOGLE_CLOUD_PROJECT")
    or _gcloud_value(["config", "get-value", "project"])
)
if not PROJECT_ID or PROJECT_ID in ("(unset)", "your-gcp-project-id"):
    sys.exit("ERROR: PROJECT_ID is required. Set PROJECT_ID via environment variable or .env.")

PROJECT_NUMBER = os.environ.get("PROJECT_NUMBER") or _gcloud_value(
    ["projects", "describe", PROJECT_ID, "--format=value(projectNumber)"]
)
ORG_ID = os.environ.get("ORG_ID") or ""
if not ORG_ID:
    ancestors_raw = _gcloud_value(["projects", "get-ancestors", PROJECT_ID, "--format=json"])
    if ancestors_raw:
        try:
            ORG_ID = next((x["id"] for x in json.loads(ancestors_raw) if x.get("type") == "organization"), "")
        except Exception:
            ORG_ID = ""

REGION = os.environ.get("REGION") or os.environ.get("GOOGLE_CLOUD_LOCATION") or "us-central1"
MODEL_LOCATION = os.environ.get("MODEL_LOCATION", "global")
MODEL_NAME = os.environ.get("MODEL_NAME", "gemini-3.8-flash")
INGRESS_GATEWAY_NAME = os.environ.get("INGRESS_GATEWAY_NAME", "ingress-gw")
EGRESS_GATEWAY_NAME = os.environ.get("EGRESS_GATEWAY_NAME", "liveops-egress-gw")
MCP_URL = os.environ.get("MCP_URL", "")
SRE_URL = os.environ.get("SRE_URL", "")
BILLING_URL = os.environ.get("BILLING_URL", "")
EXISTING_RESOURCE_NAME = os.environ.get("ORCHESTRATOR_RESOURCE_NAME", "").strip()
STAGING_BUCKET = os.environ.get("STAGING_BUCKET") or f"gs://{PROJECT_ID}-agent-gov-staging"


def get_gcloud_creds() -> google.oauth2.credentials.Credentials:
    token = subprocess.check_output(["gcloud", "auth", "print-access-token", "--quiet"], text=True).strip()
    return google.oauth2.credentials.Credentials(token=token)


def ensure_staging_bucket() -> None:
    res = subprocess.run(
        ["gcloud", "storage", "buckets", "describe", STAGING_BUCKET, f"--project={PROJECT_ID}"],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        print(f"Creating staging bucket {STAGING_BUCKET} in {REGION}...")
        subprocess.run(
            [
                "gcloud",
                "storage",
                "buckets",
                "create",
                STAGING_BUCKET,
                f"--location={REGION}",
                f"--project={PROJECT_ID}",
            ],
            check=True,
        )


def grant_principal_set_iam() -> None:
    if not ORG_ID or not PROJECT_NUMBER:
        return
    principal_set = f"principalSet://agents.global.org-{ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/{PROJECT_NUMBER}"
    for role in ("roles/aiplatform.user", "roles/agentregistry.viewer", "roles/serviceusage.serviceUsageConsumer"):
        print(f"Granting {role} to {principal_set}...")
        subprocess.run(
            [
                "gcloud",
                "projects",
                "add-iam-policy-binding",
                PROJECT_ID,
                f"--member={principal_set}",
                f"--role={role}",
                "--condition=None",
                "--quiet",
            ],
            check=False,
        )


def main() -> None:
    is_in_place_update = bool(EXISTING_RESOURCE_NAME and "--recreate" not in sys.argv)
    if not is_in_place_update:
        ensure_staging_bucket()
        grant_principal_set_iam()

    creds = get_gcloud_creds()
    vertexai.init(project=PROJECT_ID, location=REGION, staging_bucket=STAGING_BUCKET, credentials=creds)
    client = vertexai.Client(project=PROJECT_ID, location=REGION, credentials=creds)

    ingress_gw_res = f"projects/{PROJECT_ID}/locations/{REGION}/agentGateways/{INGRESS_GATEWAY_NAME}"
    egress_gw_res = f"projects/{PROJECT_ID}/locations/{REGION}/agentGateways/{EGRESS_GATEWAY_NAME}"

    # Note: Gemini Agent Runtime automatically injects GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION,
    # and GOOGLE_CLOUD_AGENT_ENGINE_ID at container runtime, and agent.py reads projectNumber from GCP Metadata Server.
    runtime_env_vars: dict[str, str] = {
        "MODEL_LOCATION": MODEL_LOCATION,
        "MODEL_NAME": MODEL_NAME,
        "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES": "False",
    }
    if ORG_ID:
        runtime_env_vars["ORG_ID"] = ORG_ID
    if MCP_URL:
        runtime_env_vars["MCP_URL"] = MCP_URL
    if SRE_URL:
        runtime_env_vars["SRE_URL"] = SRE_URL
    if BILLING_URL:
        runtime_env_vars["BILLING_URL"] = BILLING_URL

    common_config = {
        "display_name": "game-liveops-orchestrator",
        "description": "Enterprise Game LiveOps Customer Support & Governance Orchestrator Agent",
        "staging_bucket": STAGING_BUCKET,
        "requirements": [
            "google-adk>=1.20.0",
            "google-cloud-aiplatform[agent_engines,adk]>=1.95.0",
            "google-genai>=1.16.0",
            "google-auth>=2.35.0",
            "httpx>=0.27.0",
            "requests>=2.32.0",
            "pydantic>=2.9.0",
            "cloudpickle>=3.0.0",
        ],
        "env_vars": runtime_env_vars,
    }

    if is_in_place_update:
        print(f"Updating existing ReasoningEngine IN-PLACE: {EXISTING_RESOURCE_NAME}")
        remote_agent = client.agent_engines.update(
            name=EXISTING_RESOURCE_NAME,
            agent=root_agent,
            config=common_config,
        )
    else:
        print(f"Creating new game-liveops-orchestrator in Agent Runtime ({PROJECT_ID} / {REGION})...")
        create_cfg = dict(common_config)
        create_cfg["identity_type"] = vtypes.IdentityType.AGENT_IDENTITY
        create_cfg["agent_gateway_config"] = {
            "client_to_agent_config": {
                "agent_gateway": ingress_gw_res,
            },
            "agent_to_anywhere_config": {
                "agent_gateway": egress_gw_res,
            },
        }
        remote_agent = client.agent_engines.create(
            agent=root_agent,
            config=create_cfg,
        )

    resource_name = remote_agent.api_resource.name
    engine_id = resource_name.split("/")[-1]
    spiffe_principal = (
        f"principal://agents.global.org-{ORG_ID}.system.id.goog/"
        f"resources/aiplatform/projects/{PROJECT_NUMBER}/locations/{REGION}/reasoningEngines/{engine_id}"
        if ORG_ID and PROJECT_NUMBER
        else ""
    )

    print("==========================================")
    print(f"Active ReasoningEngine  : {resource_name}")
    print(f"ReasoningEngine ID      : {engine_id}")
    if spiffe_principal:
        print(f"SPIFFE Agent Identity   : {spiffe_principal}")
    print("==========================================")

    if not is_in_place_update and spiffe_principal:
        for role in ("roles/aiplatform.user", "roles/agentregistry.viewer", "roles/serviceusage.serviceUsageConsumer"):
            subprocess.run(
                [
                    "gcloud",
                    "projects",
                    "add-iam-policy-binding",
                    PROJECT_ID,
                    f"--member={spiffe_principal}",
                    f"--role={role}",
                    "--condition=None",
                    "--quiet",
                ],
                check=False,
            )

    env_path = ROOT_DIR / ".env"
    existing_lines = env_path.read_text().splitlines() if env_path.exists() else []
    lines = [
        line
        for line in existing_lines
        if not line.startswith(("ORCHESTRATOR_ENGINE_ID=", "ORCHESTRATOR_RESOURCE_NAME=", "ORCHESTRATOR_SPIFFE_ID="))
    ]
    lines.append(f"ORCHESTRATOR_ENGINE_ID={engine_id}")
    lines.append(f"ORCHESTRATOR_RESOURCE_NAME={resource_name}")
    if spiffe_principal:
        lines.append(f"ORCHESTRATOR_SPIFFE_ID={spiffe_principal}")
    env_path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
