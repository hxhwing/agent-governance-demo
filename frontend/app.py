import json
import os
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from dotenv import dotenv_values
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from functools import lru_cache
from pydantic import BaseModel

ROOT_DIR = Path(__file__).resolve().parent.parent
FRONTEND_DIR = ROOT_DIR / "frontend"
STATIC_DIR = FRONTEND_DIR / "static"

app = FastAPI(title="Game LiveOps Security & Governance Command Center")
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@lru_cache(maxsize=1)
def _default_gcloud_project() -> str:
    try:
        proj = subprocess.check_output(
            ["gcloud", "config", "get-value", "project"],
            stdin=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        ).strip()
        return "" if proj == "(unset)" else proj
    except Exception:
        return ""


def get_env() -> Dict[str, str]:
    env_file = ROOT_DIR / ".env"
    file_vals = {k: v for k, v in dotenv_values(env_file).items() if v is not None} if env_file.exists() else {}
    merged: Dict[str, str] = {**file_vals, **dict(os.environ)}
    if not merged.get("PROJECT_ID"):
        merged["PROJECT_ID"] = merged.get("GOOGLE_CLOUD_PROJECT") or _default_gcloud_project()
    if not merged.get("REGION"):
        merged["REGION"] = merged.get("GOOGLE_CLOUD_LOCATION") or "us-central1"
    return merged


def get_token() -> str:
    env_token = os.environ.get("GCP_ACCESS_TOKEN")
    if env_token:
        return env_token
    try:
        return subprocess.check_output(
            ["gcloud", "auth", "print-access-token", "--quiet"],
            stdin=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=12,
        ).strip()
    except Exception:
        try:
            import google.auth
            import google.auth.transport.requests
            creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
            creds.refresh(google.auth.transport.requests.Request())
            return creds.token or ""
        except Exception:
            return ""


class ScenarioRequest(BaseModel):
    scenario_id: str = "custom"
    prompt: str
    user_id: str = "liveops-demo-operator"
    session_id: Optional[str] = None


class NewSessionRequest(BaseModel):
    user_id: Optional[str] = None


ACTIVE_SESSIONS: Dict[str, str] = {}


def _get_or_create_engine_session(
    project_id: str,
    location: str,
    engine_id: str,
    user_id: str,
    headers: Dict[str, str],
    force_new: bool = False,
) -> Optional[str]:
    if not engine_id:
        return None
    if not force_new and user_id in ACTIVE_SESSIONS:
        return ACTIVE_SESSIONS[user_id]
    try:
        q_url = f"https://{location}-aiplatform.googleapis.com/v1/projects/{project_id}/locations/{location}/reasoningEngines/{engine_id}:query"
        r = requests.post(
            q_url,
            headers=headers,
            json={"class_method": "async_create_session", "input": {"user_id": user_id}},
            timeout=15,
        )
        if r.status_code == 200:
            sid = str(r.json().get("output", {}).get("id", "")).strip()
            if sid:
                ACTIVE_SESSIONS[user_id] = sid
                return sid
    except Exception:
        pass
    return None


@app.post("/api/new-session")
def create_new_session_api(req: NewSessionRequest):
    env = get_env()
    project_id = env.get("PROJECT_ID", "")
    location = env.get("REGION", "us-central1")
    engine_id = env.get("ORCHESTRATOR_ENGINE_ID", "")
    token = get_token()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    uid = req.user_id or f"liveops-op-{uuid.uuid4().hex[:6]}"
    sid = _get_or_create_engine_session(project_id, location, engine_id, uid, headers, force_new=True) if project_id else None
    return JSONResponse({
        "user_id": uid,
        "session_id": sid or "",
    })


@app.middleware("http")
async def disable_static_cache(request, call_next):
    response = await call_next(request)
    if request.url.path == "/" or request.url.path.startswith("/static/"):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    return response


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/governance-topology")
async def governance_topology():
    env = get_env()
    project_id = env.get("PROJECT_ID", "")
    project_number = env.get("PROJECT_NUMBER", "")
    org_id = env.get("ORG_ID", "")
    location = env.get("REGION", "us-central1")
    engine_id = env.get("ORCHESTRATOR_ENGINE_ID", "")
    spiffe_id = env.get("ORCHESTRATOR_SPIFFE_ID", "")
    if not spiffe_id and org_id and project_number and engine_id:
        spiffe_id = (
            f"principal://agents.global.org-{org_id}.system.id.goog/"
            f"resources/aiplatform/projects/{project_number}/locations/{location}/reasoningEngines/{engine_id}"
        )
    token = get_token()
    headers = {"Authorization": f"Bearer {token}", "x-goog-user-project": project_id} if (token and project_id) else {}

    proj_disp = project_id or "<PROJECT_ID>"
    fallback_agents = [
        {
            "name": f"projects/{proj_disp}/locations/{location}/agents/game-liveops-orchestrator",
            "displayName": "game-liveops-orchestrator",
        },
        {
            "name": f"projects/{proj_disp}/locations/{location}/agents/sre-incident-a2a-agent",
            "displayName": "SRE Incident Diagnostics A2A Agent",
        },
        {
            "name": f"projects/{proj_disp}/locations/{location}/agents/billing-refund-a2a-agent",
            "displayName": "Billing Cash Refund A2A Agent",
        },
    ]
    fallback_mcps = [
        {
            "name": f"projects/{proj_disp}/locations/{location}/mcpServers/game-liveops-mcp",
            "displayName": "Game LiveOps MCP Server",
            "tools": [
                {"name": "query_player_ticket"},
                {"name": "grant_player_compensation"},
                {"name": "ban_player_account"},
            ],
        }
    ]
    fallback_eps = [
        {
            "name": f"projects/{proj_disp}/locations/{location}/endpoints/essential-gcp-apis",
            "displayName": "Essential Google Cloud Platform APIs",
            "interfaces": [{"url": "https://aiplatform.googleapis.com"}],
        },
        {
            "name": f"projects/{proj_disp}/locations/{location}/endpoints/discord-community-webhook",
            "displayName": "Discord Community Bot Webhook",
            "interfaces": [{"url": "https://httpbin.org"}, {"url": "https://httpbin.org/post"}],
        },
    ]

    agents_list = fallback_agents
    mcps_list = fallback_mcps
    eps_list = fallback_eps
    gateways_list = []
    authz_list = []
    auth_relogin_needed = False

    if headers:
        try:
            reg_base = f"https://agentregistry.googleapis.com/v1alpha/projects/{project_id}/locations/{location}"
            agents_res = requests.get(f"{reg_base}/agents", headers=headers, timeout=6)
            mcp_res = requests.get(f"{reg_base}/mcpServers", headers=headers, timeout=6)
            ep_res = requests.get(f"{reg_base}/endpoints", headers=headers, timeout=6)
            if agents_res.status_code == 200:
                raw_agents = agents_res.json().get("agents", [])
                match_keys = ["game-liveops-orchestrator", "sre-incident-a2a-agent", "billing-refund-a2a-agent"]
                if engine_id:
                    match_keys.append(engine_id.lower())
                filtered_agents = [
                    a for a in raw_agents
                    if any(k in json.dumps(a).lower() for k in match_keys)
                ]
                agents_list = filtered_agents or fallback_agents
            else:
                auth_relogin_needed = True
            if mcp_res.status_code == 200:
                mcps_list = mcp_res.json().get("mcpServers", []) or fallback_mcps
            if ep_res.status_code == 200:
                eps_list = ep_res.json().get("endpoints", []) or fallback_eps

            gw_res = requests.get(
                f"https://networkservices.googleapis.com/v1beta1/projects/{project_id}/locations/{location}/agentGateways",
                headers=headers,
                timeout=6,
            )
            if gw_res.status_code == 200:
                gateways_list = gw_res.json().get("agentGateways", [])
        except Exception:
            auth_relogin_needed = True
    else:
        auth_relogin_needed = True

    return JSONResponse({
        "auth_relogin_needed": auth_relogin_needed,
        "environment": {
            "project_id": project_id,
            "project_number": project_number,
            "org_id": org_id,
            "region": location,
            "model": f"{env.get('MODEL_NAME', 'gemini-3.8-flash')} (location={env.get('MODEL_LOCATION', 'global')})",
            "gemini_enterprise_app_id": env.get("GEMINI_ENTERPRISE_APP_ID", ""),
            "orchestrator_engine_id": engine_id,
            "orchestrator_spiffe_id": spiffe_id,
            "ingress_gateway": env.get("INGRESS_GATEWAY_NAME", "ingress-gw"),
            "egress_gateway": env.get("EGRESS_GATEWAY_NAME", "liveops-egress-gw"),
            "model_armor_template": env.get("MODEL_ARMOR_TEMPLATE_ID", "agent-gov-ma-template"),
        },
        "registry": {
            "agents": agents_list,
            "mcpServers": mcps_list,
            "endpoints": eps_list,
        },
        "gateways": gateways_list,
        "authz_policies": authz_list,
    })


def _inspect_raw_tool_response(fr: Dict[str, Any]) -> Dict[str, Any]:
    """Unwrap nested JSON strings in tool function_response without adding synthetic wrappers, and identify raw governance source."""
    engine = "normal"
    status = "ALLOW"
    raw_detail: Any = None
    try:
        raw_res_str = fr.get("response", {}).get("result")
        if isinstance(raw_res_str, str):
            parsed_res = json.loads(raw_res_str)
            http_code = parsed_res.get("http_status")
            raw_body = parsed_res.get("raw_response")

            if isinstance(raw_body, dict):
                mcp_res = raw_body.get("result")
                if isinstance(mcp_res, dict) and isinstance(mcp_res.get("content"), list):
                    for c_item in mcp_res["content"]:
                        if isinstance(c_item, dict) and isinstance(c_item.get("text"), str):
                            try:
                                c_data = json.loads(c_item["text"])
                                c_item["data"] = c_data
                                del c_item["text"]
                                if isinstance(c_data, dict) and "sgpEvaluation" in c_data:
                                    engine = "sgp_allow"
                                    raw_detail = c_data.get("sgpEvaluation")
                            except Exception:
                                pass

                if "sgpEvaluation" in raw_body:
                    engine = "sgp"
                    status = "BLOCKED"
                    raw_detail = raw_body
                    fr["response"]["result"] = json.dumps(raw_body, ensure_ascii=False, indent=2)
                    return {"engine": engine, "status": status, "raw_detail": raw_detail}

                if "sanitizationResult" in raw_body:
                    engine = "model_armor_sdp"
                    status = "BLOCKED"
                    raw_detail = raw_body
                    fr["response"]["result"] = json.dumps(raw_body, ensure_ascii=False, indent=2)
                    return {"engine": engine, "status": status, "raw_detail": raw_detail}

            if http_code is not None and int(http_code) >= 400:
                engine = "iap_uap"
                status = "BLOCKED"
                raw_detail = parsed_res
            elif parsed_res.get("transport_error"):
                engine = "iap_uap"
                status = "BLOCKED"
                raw_detail = parsed_res

            fr["response"]["result"] = json.dumps(parsed_res, ensure_ascii=False, indent=2)
    except Exception:
        pass
    return {"engine": engine, "status": status, "raw_detail": raw_detail}


def _classify_path_from_fc(fc: Dict[str, Any]) -> str:
    fname = fc.get("name", "")
    if fname in (
        "call_mcp_server_tool",
        "query_player_ticket",
        "grant_player_compensation",
        "ban_player_account",
    ):
        return "agent_to_mcp"
    if fname == "call_registered_a2a_agent":
        return "agent_to_agent"
    if fname in ("send_webhook_notification", "call_external_endpoint"):
        return "agent_to_endpoint"
    return "agent_to_model"


@app.post("/api/run-scenario")
async def run_scenario(req: ScenarioRequest):
    env = get_env()
    project_id = env.get("PROJECT_ID", "")
    location = env.get("REGION", "us-central1")
    engine_id = env.get("ORCHESTRATOR_ENGINE_ID", "")
    if not project_id:
        raise HTTPException(status_code=503, detail="PROJECT_ID is not configured in .env or environment.")
    if not engine_id:
        raise HTTPException(status_code=503, detail="ORCHESTRATOR_ENGINE_ID not yet set in .env (Agent Runtime deployment in progress).")
    token = get_token()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    start_ts = time.time()
    trace_steps: List[Dict[str, Any]] = []
    active_paths: List[str] = ["client_to_agent"]
    blocked_node: Optional[str] = None
    verdict_status = "ALLOW"
    verdict_badge = "PASS — GOVERNED & ALLOWED"
    governance_layer = "Multi-Layer Governance"

    active_session_id = req.session_id
    if not active_session_id and req.user_id != "liveops-demo-operator":
        active_session_id = _get_or_create_engine_session(project_id, location, engine_id, req.user_id, headers)

    stream_url = f"https://{location}-aiplatform.googleapis.com/v1/projects/{project_id}/locations/{location}/reasoningEngines/{engine_id}:streamQuery?alt=sse"
    query_input: Dict[str, Any] = {
        "user_id": req.user_id,
        "message": req.prompt,
    }
    if active_session_id:
        query_input["session_id"] = active_session_id
    payload = {
        "class_method": "async_stream_query",
        "input": query_input,
    }

    events: List[Dict[str, Any]] = []
    final_text_parts: List[str] = []
    tool_calls_seen: List[Dict[str, Any]] = []
    tool_responses_seen: List[Dict[str, Any]] = []
    inspected_engines: List[str] = []
    http_status = 200
    raw_error_text = ""

    try:
        resp = requests.post(stream_url, headers=headers, json=payload, timeout=75)
        http_status = resp.status_code
        if http_status != 200:
            raw_error_text = resp.text
        else:
            active_paths.append("agent_to_model")
            for line in resp.text.splitlines():
                line_str = line.strip()
                if not line_str:
                    continue
                if line_str.startswith("data:"):
                    line_str = line_str[5:].strip()
                try:
                    ev = json.loads(line_str)
                    events.append(ev)
                    content = ev.get("content", {})
                    for part in content.get("parts", []):
                        if "text" in part and part["text"]:
                            final_text_parts.append(part["text"])
                        if "function_call" in part and part["function_call"]:
                            fc = part["function_call"]
                            tool_calls_seen.append(fc)
                        if "function_response" in part and part["function_response"]:
                            fr = part["function_response"]
                            info = _inspect_raw_tool_response(fr)
                            inspected_engines.append(info["engine"])
                            tool_responses_seen.append(fr)
                except Exception:
                    final_text_parts.append(line_str)
    except Exception as e:
        http_status = 500
        raw_error_text = str(e)

    combined_reply = "\n".join(final_text_parts).strip() or raw_error_text
    all_serialized = json.dumps(
        {"events": events, "error": raw_error_text, "reply": combined_reply},
        ensure_ascii=False,
    )

    for fc in tool_calls_seen:
        ptype = _classify_path_from_fc(fc)
        if ptype not in active_paths:
            active_paths.append(ptype)

    ingress_blocked = http_status != 200 and "Model Armor: Prompt violates" in raw_error_text
    trace_steps.append({
        "step": "1. Ingress Agent Gateway (CLIENT_TO_AGENT)",
        "component": "ingress-gw + Model Armor (CONTENT_AUTHZ)",
        "status": "BLOCKED" if ingress_blocked else "ALLOW",
        "detail": (
            "请求在入口网关 (ingress-gw) 经 Model Armor 判定违规并直接返回 HTTP 403，流量未进入 Agent。"
            if ingress_blocked
            else "请求已通过入口网关 (ingress-gw + Model Armor) 并转发至 Agent Runtime。"
        ),
    })

    # Classify blocks strictly from authentic gateway / runtime responses
    if ingress_blocked:
        verdict_status = "BLOCKED"
        blocked_node = "ingress_ma"
        verdict_badge = "BLOCKED BY INGRESS GATEWAY + MODEL ARMOR (HTTP 403)"
        governance_layer = "Ingress Gateway + Model Armor (CONTENT_AUTHZ)"
    elif "model_armor_sdp" in inspected_engines or "Response violates content security configurations" in all_serialized:
        verdict_status = "BLOCKED"
        blocked_node = "egress_ma"
        verdict_badge = "BLOCKED BY MODEL ARMOR (SDP PII FILTER)"
        governance_layer = "Model Armor Sensitive Data Protection (SDP)"
    elif "sgp" in inspected_engines or "Semantic Governance Policy denied tool" in all_serialized:
        verdict_status = "BLOCKED"
        blocked_node = "egress_sgp"
        verdict_badge = "BLOCKED BY SEMANTIC GOVERNANCE POLICY (SGP)"
        governance_layer = "Semantic Governance Policy (SGP)"
    elif "iap_uap" in inspected_engines or "Egress request is not authorized" in all_serialized:
        verdict_status = "BLOCKED"
        blocked_node = "egress_iap"
        verdict_badge = "BLOCKED BY AGENT GATEWAY IAP / IAM UAP (HTTP 403)"
        governance_layer = "Agent Gateway + IAM Unified Access Policy (REQUEST_AUTHZ)"

    if http_status == 200:
        trace_steps.append({
            "step": "2. Agent Runtime & Egress Gateway Execution",
            "component": f"game-liveops-orchestrator -> liveops-egress-gw (HTTP {http_status})",
            "status": verdict_status,
            "detail": f"Tool calls: {[fc.get('name') for fc in tool_calls_seen] or ['None']}",
            "tool_calls": tool_calls_seen,
            "tool_responses": tool_responses_seen,
        })

    elapsed_ms = int((time.time() - start_ts) * 1000)
    return JSONResponse({
        "scenario_id": req.scenario_id,
        "prompt": req.prompt,
        "http_status": http_status,
        "verdict_status": verdict_status,
        "verdict_badge": verdict_badge,
        "governance_layer": governance_layer,
        "blocked_node": blocked_node,
        "active_paths": active_paths,
        "reply": combined_reply,
        "tool_calls": tool_calls_seen,
        "tool_responses": tool_responses_seen,
        "trace_steps": trace_steps,
        "elapsed_ms": elapsed_ms,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


@app.post("/api/stream-scenario")
def stream_scenario(req: ScenarioRequest):
    env = get_env()
    project_id = env.get("PROJECT_ID", "")
    location = env.get("REGION", "us-central1")
    engine_id = env.get("ORCHESTRATOR_ENGINE_ID", "")
    spiffe_id = env.get("ORCHESTRATOR_SPIFFE_ID", "")
    if not project_id or not engine_id:
        raise HTTPException(status_code=503, detail="PROJECT_ID and ORCHESTRATOR_ENGINE_ID must be configured in .env or environment.")
    token = get_token()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    def sse_pack(event_type: str, payload: Dict[str, Any]) -> str:
        return f"event: {event_type}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"

    def event_generator():
        start_ts = time.time()
        trace_steps: List[Dict[str, Any]] = []
        active_paths: List[str] = ["client_to_agent"]
        blocked_node: Optional[str] = None
        verdict_status = "ALLOW"
        verdict_badge = "PASS — GOVERNED & ALLOWED"
        governance_layer = "Multi-Layer Governance"

        # Send message directly to Agent Runtime (:streamQuery); cloud ingress-gw + Model Armor inspects automatically
        active_session_id = req.session_id
        if not active_session_id and req.user_id != "liveops-demo-operator":
            active_session_id = _get_or_create_engine_session(project_id, location, engine_id, req.user_id, headers)

        stream_url = f"https://{location}-aiplatform.googleapis.com/v1/projects/{project_id}/locations/{location}/reasoningEngines/{engine_id}:streamQuery?alt=sse"
        query_input: Dict[str, Any] = {
            "user_id": req.user_id,
            "message": req.prompt,
        }
        if active_session_id:
            query_input["session_id"] = active_session_id
        payload = {
            "class_method": "async_stream_query",
            "input": query_input,
        }

        events: List[Dict[str, Any]] = []
        final_text_parts: List[str] = []
        tool_calls_seen: List[Dict[str, Any]] = []
        tool_responses_seen: List[Dict[str, Any]] = []
        inspected_engines: List[str] = []
        http_status = 200
        raw_error_text = ""

        try:
            with requests.post(stream_url, headers=headers, json=payload, stream=True, timeout=90) as resp:
                http_status = resp.status_code
                hop1_ms = int((time.time() - start_ts) * 1000)
                if http_status != 200:
                    raw_error_text = resp.text
                    is_ma_block = "Model Armor: Prompt violates" in raw_error_text
                    hop1_step = {
                        "step": "1. Ingress Agent Gateway (CLIENT_TO_AGENT)",
                        "component": f"ingress-gw + Model Armor ({hop1_ms} ms)",
                        "status": "BLOCKED",
                        "detail": (
                            "Model Armor 判定 Prompt 违反内容安全配置，由入口网关 (ingress-gw) 直接返回 HTTP 403（流量未进入 Agent）！"
                            if is_ma_block
                            else f"入口网关返回 HTTP {http_status}（请求未进入 Agent）。"
                        ),
                    }
                    trace_steps.append(hop1_step)
                    yield sse_pack("ingress_check", hop1_step)

                    gw_headers = {
                        k: v
                        for k, v in resp.headers.items()
                        if k.lower() in ("content-type", "date", "server", "via", "x-goog-iap-generated-response")
                    }
                    try:
                        parsed_gw_err: Any = json.loads(raw_error_text)
                    except Exception:
                        parsed_gw_err = raw_error_text
                    yield sse_pack("gateway_error", {
                        "http_status": http_status,
                        "headers": gw_headers,
                        "raw_gateway_response": parsed_gw_err,
                        "error_text": raw_error_text,
                    })
                else:
                    hop1_step = {
                        "step": "1. Ingress Agent Gateway (CLIENT_TO_AGENT)",
                        "component": f"ingress-gw + Model Armor ({hop1_ms} ms)",
                        "status": "ALLOW",
                        "detail": "请求已通过入口网关 (ingress-gw + Model Armor) 安全审查并转发至 Agent Runtime。",
                    }
                    trace_steps.append(hop1_step)
                    yield sse_pack("ingress_check", hop1_step)

                    active_paths.append("agent_to_model")
                    yield sse_pack("runtime_start", {
                        "engine_id": engine_id,
                        "session_id": active_session_id or "",
                        "spiffe_id": spiffe_id,
                        "model": f"{env.get('MODEL_NAME', 'gemini-3.8-flash')} (global)",
                        "egress_gateway": env.get("EGRESS_GATEWAY_NAME", "liveops-egress-gw"),
                        "active_paths": list(active_paths),
                    })
                    for raw_line in resp.iter_lines(decode_unicode=True):
                        if not raw_line:
                            continue
                        line_str = raw_line.strip()
                        if line_str.startswith("data:"):
                            line_str = line_str[5:].strip()
                        if not line_str:
                            continue
                        try:
                            ev = json.loads(line_str)
                            events.append(ev)
                            content = ev.get("content", {})
                            for part in content.get("parts", []):
                                if "function_call" in part and part["function_call"]:
                                    fc = part["function_call"]
                                    tool_calls_seen.append(fc)
                                    path_type = _classify_path_from_fc(fc)
                                    if path_type not in active_paths:
                                        active_paths.append(path_type)
                                    yield sse_pack("tool_call", {
                                        "function_call": fc,
                                        "path_type": path_type,
                                        "active_paths": list(active_paths),
                                        "elapsed_ms": int((time.time() - start_ts) * 1000),
                                    })
                                if "function_response" in part and part["function_response"]:
                                    fr = part["function_response"]
                                    info = _inspect_raw_tool_response(fr)
                                    inspected_engines.append(info["engine"])
                                    tool_responses_seen.append(fr)
                                    yield sse_pack("tool_response", {
                                        "function_response": fr,
                                        "status": info["status"],
                                        "raw_engine": info["engine"],
                                        "elapsed_ms": int((time.time() - start_ts) * 1000),
                                    })
                                if "text" in part and part["text"]:
                                    txt = part["text"]
                                    final_text_parts.append(txt)
                                    yield sse_pack("agent_text", {
                                        "text": txt,
                                        "elapsed_ms": int((time.time() - start_ts) * 1000),
                                    })
                        except Exception:
                            final_text_parts.append(line_str)
                            yield sse_pack("agent_text", {"text": line_str})
        except Exception as e:
            http_status = 500
            raw_error_text = str(e)
            yield sse_pack("gateway_error", {"http_status": 500, "error_text": raw_error_text})

        combined_reply = "\n".join(final_text_parts).strip()
        all_serialized = json.dumps(
            {"events": events, "error": raw_error_text, "reply": combined_reply},
            ensure_ascii=False,
        )

        if http_status != 200 and "Model Armor: Prompt violates" in raw_error_text:
            verdict_status = "BLOCKED"
            blocked_node = "ingress_ma"
            verdict_badge = "BLOCKED BY INGRESS GATEWAY + MODEL ARMOR (HTTP 403)"
            governance_layer = "Ingress Gateway + Model Armor (CONTENT_AUTHZ)"
        elif "model_armor_sdp" in inspected_engines or "Response violates content security configurations" in all_serialized:
            verdict_status = "BLOCKED"
            blocked_node = "egress_ma"
            verdict_badge = "BLOCKED BY MODEL ARMOR (SDP PII FILTER)"
            governance_layer = "Model Armor Sensitive Data Protection (SDP)"
        elif "sgp" in inspected_engines or "Semantic Governance Policy denied tool" in all_serialized:
            verdict_status = "BLOCKED"
            blocked_node = "egress_sgp"
            verdict_badge = "BLOCKED BY SEMANTIC GOVERNANCE POLICY (SGP)"
            governance_layer = "Semantic Governance Policy (SGP)"
        elif "iap_uap" in inspected_engines or "Egress request is not authorized" in all_serialized:
            verdict_status = "BLOCKED"
            blocked_node = "egress_iap"
            verdict_badge = "BLOCKED BY AGENT GATEWAY IAP / IAM UAP (HTTP 403)"
            governance_layer = "Agent Gateway + IAM Unified Access Policy (REQUEST_AUTHZ)"

        if http_status == 200:
            trace_steps.append({
                "step": "2. Agent Runtime & Egress Gateway Execution",
                "component": f"game-liveops-orchestrator -> liveops-egress-gw (HTTP {http_status})",
                "status": verdict_status,
                "detail": f"Tool calls: {[fc.get('name') for fc in tool_calls_seen] or ['None']}",
                "tool_calls": tool_calls_seen,
                "tool_responses": tool_responses_seen,
            })

        elapsed_ms = int((time.time() - start_ts) * 1000)
        yield sse_pack("final_verdict", {
            "scenario_id": req.scenario_id,
            "prompt": req.prompt,
            "http_status": http_status,
            "verdict_status": verdict_status,
            "verdict_badge": verdict_badge,
            "governance_layer": governance_layer,
            "blocked_node": blocked_node,
            "active_paths": active_paths,
            "reply": combined_reply,
            "tool_calls": tool_calls_seen,
            "tool_responses": tool_responses_seen,
            "trace_steps": trace_steps,
            "elapsed_ms": elapsed_ms,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })

    return StreamingResponse(event_generator(), media_type="text/event-stream")


class SgpPolicyUpdateRequest(BaseModel):
    policyPreset: Optional[str] = None
    maxGems: Optional[int] = None
    forbiddenRarities: Optional[List[str]] = None
    sgpUserIntentMatchingMode: Optional[str] = None
    mcpToolRules: Optional[List[Dict[str, Any]]] = None


@app.get("/api/uap-policy")
def get_uap_policy_api():
    env = get_env()
    project_id = env.get("PROJECT_ID", "") or "<PROJECT_ID>"
    location = env.get("REGION", "us-central1")
    egress_gw = env.get("EGRESS_GATEWAY_NAME", "liveops-egress-gw")
    uap_policy_id = env.get("UAP_POLICY_ID", "liveops-egress-uap-policy")
    spiffe_id = env.get(
        "ORCHESTRATOR_SPIFFE_ID",
        "principal://agents.global.org-<ORG_ID>.system.id.goog/resources/aiplatform/projects/<PROJECT_NUMBER>/locations/us-central1/reasoningEngines/<ENGINE_ID>",
    )
    if project_id != "<PROJECT_ID>":
        try:
            token = get_token()
            r = requests.get(
                f"https://iam.googleapis.com/v3beta/projects/{project_id}/locations/global/accessPolicies/{uap_policy_id}",
                headers={"Authorization": f"Bearer {token}", "x-goog-user-project": project_id},
                timeout=8,
            )
            if r.status_code == 200:
                return JSONResponse({
                    "gateway": f"projects/{project_id}/locations/{location}/agentGateways/{egress_gw}",
                    "iapExtension": f"projects/{project_id}/locations/{location}/authzExtensions/liveops-egress-iap-ext",
                    "policyBinding": f"projects/{project_id}/locations/global/policyBindings/liveops-egress-uap-binding",
                    "accessPolicy": r.json(),
                })
        except Exception:
            pass
    return JSONResponse({
        "gateway": f"projects/{project_id}/locations/{location}/agentGateways/{egress_gw}",
        "iapExtension": f"projects/{project_id}/locations/{location}/authzExtensions/liveops-egress-iap-ext",
        "policyBinding": f"projects/{project_id}/locations/global/policyBindings/liveops-egress-uap-binding",
        "accessPolicy": {
            "name": f"projects/{project_id}/locations/global/accessPolicies/{uap_policy_id}",
            "displayName": "Game LiveOps Egress UAP Allowlist Policy",
            "details": {
                "rules": [
                    {
                        "description": "Zero-trust allowlist: Essential GCP APIs, Discord Webhook, SRE A2A Agent, and ONLY MCP tools [query_player_ticket, grant_player_compensation]. All else denied by default.",
                        "effect": "ALLOW",
                        "principals": [spiffe_id],
                        "operation": {"permissions": ["iap.googleapis.com/resources.egressViaIAP"]},
                        "conditions": {
                            "iap.googleapis.com": {
                                "title": "AllowExplicitLiveOpsTargetsAndToolList",
                                "expression": (
                                    f"destination.agent_registry.endpoint.name == 'projects/{project_id}/locations/{location}/endpoints/<ESSENTIAL_GCP_APIS_ENDPOINT>' || "
                                    f"destination.agent_registry.endpoint.name == 'projects/{project_id}/locations/{location}/endpoints/<DISCORD_WEBHOOK_ENDPOINT>' || "
                                    f"destination.agent_registry.agent.name == 'projects/{project_id}/locations/{location}/agents/<SRE_INCIDENT_A2A_AGENT>' || "
                                    f"(destination.agent_registry.mcp_server.name == 'projects/{project_id}/locations/{location}/mcpServers/<GAME_LIVEOPS_MCP_SERVER>' && "
                                    "(destination.agent_registry.mcp_server.tool.name == 'query_player_ticket' || destination.agent_registry.mcp_server.tool.name == 'grant_player_compensation'))"
                                ),
                            }
                        },
                    }
                ]
            },
        },
    })


@app.get("/api/sgp-policy")
def get_sgp_policy_api():
    env = get_env()
    project_id = env.get("PROJECT_ID", "") or "<PROJECT_ID>"
    location = env.get("REGION", "us-central1")
    sgp_policy_id = env.get("SGP_POLICY_ID", "liveops-compensation-cap-policy")
    mcp_url = env.get("MCP_URL", "").rstrip("/")
    if mcp_url:
        try:
            r = requests.get(f"{mcp_url}/admin/sgp-policy", timeout=10)
            if r.status_code == 200:
                return JSONResponse(r.json())
        except Exception:
            pass
    return JSONResponse({
        "name": f"projects/{project_id}/locations/{location}/semanticGovernancePolicies/{sgp_policy_id}",
        "displayName": f"客服自动赔付合规基线策略 ({sgp_policy_id})",
        "agent": f"projects/{project_id}/locations/{location}/agents/game-liveops-orchestrator",
        "sgpUserIntentMatchingMode": "CONSTRAINTS_AND_INTENT",
        "policyPreset": "default",
        "mcpToolRules": [
            {
                "id": "rule-default-comp",
                "mcpServer": "game-liveops-mcp",
                "tool": "grant_player_compensation",
                "enabled": True,
                "naturalLanguageConstraint": "自动赔付合规基线：(1) 金额阈值：单笔发放上限为 500 金币（≤ 500 允许自动执行，≥ 501 默认拒绝并转人工审批）；(2) 准入事由：仅限因服务端客观技术故障（区服网络闪断、节点宕机、数据异常或已确认的系统缺陷）直接导致的被动资产损失；凡属非服务端异常引发的申诉（包括客户端正常购买/兑换与道具消耗、概率性玩法结果未达预期、限时活动逾期未领及账号共享争议），严禁发放补偿。",
            }
        ],
    })


@app.post("/api/sgp-policy")
def update_sgp_policy_api(req: SgpPolicyUpdateRequest):
    env = get_env()
    mcp_url = env.get("MCP_URL", "").rstrip("/")
    if not mcp_url:
        raise HTTPException(status_code=503, detail="MCP_URL is not configured in .env or environment.")
    payload = req.model_dump(exclude_none=True)
    r = requests.post(f"{mcp_url}/admin/sgp-policy", json=payload, timeout=15)
    return JSONResponse(r.json(), status_code=r.status_code)


@app.post("/api/sgp-policy/reset")
def reset_sgp_policy_api():
    env = get_env()
    mcp_url = env.get("MCP_URL", "").rstrip("/")
    if not mcp_url:
        raise HTTPException(status_code=503, detail="MCP_URL is not configured in .env or environment.")
    r = requests.post(f"{mcp_url}/admin/sgp-policy/reset", timeout=15)
    return JSONResponse(r.json(), status_code=r.status_code)
