import json
import os
import uuid
from functools import cached_property
from typing import Any, AsyncGenerator, Dict, Optional, Tuple

import google.auth
import google.auth.transport.requests
import requests
from google.adk.agents import LlmAgent
from google.adk.models.google_llm import Gemini
from google.adk.models.llm_request import LlmRequest
from google.adk.models.llm_response import LlmResponse
from google.genai import Client


def _query_gcp_metadata(path: str) -> str:
    """Read project/instance attributes from GCP Metadata Server when running in Gemini Agent Runtime / Cloud Run."""
    try:
        resp = requests.get(
            f"http://metadata.google.internal/computeMetadata/v1/{path.lstrip('/')}",
            headers={"Metadata-Flavor": "Google"},
            timeout=2,
        )
        if resp.status_code == 200:
            return resp.text.strip()
    except Exception:
        pass
    return ""


_RUNTIME_ENV_CACHE: Dict[str, str] = {}


def _get_runtime_env() -> Dict[str, str]:
    """Resolve runtime project, location, and engine identity from Gemini Agent Runtime default env vars + Metadata Server."""
    if _RUNTIME_ENV_CACHE:
        return _RUNTIME_ENV_CACHE
    # Gemini Agent Runtime automatically injects GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION, GOOGLE_CLOUD_AGENT_ENGINE_ID
    project_id = (
        os.environ.get("GOOGLE_CLOUD_PROJECT")
        or os.environ.get("PROJECT_ID")
        or _query_gcp_metadata("project/project-id")
    )
    if not project_id:
        try:
            _, default_proj = google.auth.default()
            project_id = default_proj or ""
        except Exception:
            project_id = ""

    project_number = (
        os.environ.get("PROJECT_NUMBER")
        or _query_gcp_metadata("project/numeric-project-id")
    )

    raw_region = (
        os.environ.get("GOOGLE_CLOUD_LOCATION")
        or os.environ.get("GOOGLE_CLOUD_REGION")
        or os.environ.get("REGISTRY_LOCATION")
        or os.environ.get("REGION")
        or _query_gcp_metadata("instance/region")
    )
    # Metadata server returns 'projects/<num>/regions/<region>'
    location = raw_region.split("/")[-1] if raw_region else "us-central1"

    engine_id = (
        os.environ.get("GOOGLE_CLOUD_AGENT_ENGINE_ID")
        or os.environ.get("ORCHESTRATOR_ENGINE_ID")
        or ""
    )
    org_id = os.environ.get("ORG_ID") or ""

    _RUNTIME_ENV_CACHE.update({
        "project_id": project_id,
        "project_number": project_number,
        "location": location,
        "engine_id": engine_id,
        "org_id": org_id,
        "model_location": os.environ.get("MODEL_LOCATION", "global"),
        "model_name": os.environ.get("MODEL_NAME", "gemini-3.8-flash"),
    })
    return _RUNTIME_ENV_CACHE


class NonStreamingGlobalGemini(Gemini):
    """Gemini model adapter routing to MODEL_LOCATION (default: global) with non-streaming generateContent."""

    @cached_property
    def api_client(self) -> Client:
        rt = _get_runtime_env()
        return Client(
            vertexai=True,
            project=rt["project_id"] or None,
            location=rt["model_location"],
        )

    async def generate_content_async(
        self, llm_request: LlmRequest, stream: bool = False
    ) -> AsyncGenerator[LlmResponse, None]:
        async for resp in super().generate_content_async(llm_request, stream=False):
            yield resp


def _get_access_token() -> str:
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    auth_req = google.auth.transport.requests.Request()
    creds.refresh(auth_req)
    return creds.token


def _raw_http_result(resp: requests.Response, target_url: str, extra: Optional[Dict[str, Any]] = None) -> str:
    """Return the exact raw HTTP status, gateway headers, and raw response body without custom status wrappers."""
    interesting_headers = {
        k: v
        for k, v in resp.headers.items()
        if k.lower() in (
            "server",
            "content-type",
            "date",
            "via",
            "x-goog-iap-generated-response",
            "x-cloud-trace-context",
            "grpc-status",
            "grpc-message",
        )
    }
    raw_body: Any = resp.text
    try:
        raw_body = resp.json()
    except Exception:
        raw_body = resp.text[:1500]

    out: Dict[str, Any] = {
        "http_status": resp.status_code,
        "http_reason": resp.reason,
        "target_url": target_url,
        "response_headers": interesting_headers,
        "raw_response": raw_body,
    }
    if extra:
        out.update(extra)
    return json.dumps(out, ensure_ascii=False, indent=2)


def _resolve_mcp_url_from_registry(mcp_server_hint: str = "game-liveops-mcp") -> str:
    rt = _get_runtime_env()
    project_id = rt["project_id"]
    location = rt["location"]
    fallback_url = os.environ.get("MCP_URL", "").rstrip("/")
    if project_id:
        try:
            token = _get_access_token()
            url = f"https://agentregistry.googleapis.com/v1alpha/projects/{project_id}/locations/{location}/mcpServers"
            resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=10)
            if resp.status_code == 200:
                for srv in resp.json().get("mcpServers", []):
                    if mcp_server_hint in srv.get("name", "") or "liveops" in srv.get("displayName", "").lower():
                        for iface in srv.get("interfaces", []):
                            if iface.get("url"):
                                return iface["url"]
        except Exception:
            pass
    if fallback_url:
        return fallback_url if fallback_url.endswith("/mcp") else f"{fallback_url}/mcp"
    return ""


def inspect_governance_context() -> str:
    """Read this runtime's workload identity metadata and dynamically list all Agents, MCP Servers, and Endpoints in Agent Registry."""
    rt = _get_runtime_env()
    project_id = rt["project_id"]
    project_number = rt["project_number"]
    location = rt["location"]
    engine_id = rt["engine_id"]
    org_id = rt["org_id"]

    spiffe_id = os.environ.get("ORCHESTRATOR_SPIFFE_ID", "")
    if not spiffe_id and org_id and project_number and engine_id:
        spiffe_id = (
            f"principal://agents.global.org-{org_id}.system.id.goog/"
            f"resources/aiplatform/projects/{project_number}/locations/{location}/reasoningEngines/{engine_id}"
        )

    identity_info: Dict[str, Any] = {
        "google_cloud_project": project_id,
        "google_cloud_location": location,
        "google_cloud_agent_engine_id": engine_id,
        "project_number": project_number,
        "spiffe_agent_identity": spiffe_id or None,
        "metadata_server_identity": None,
    }
    try:
        meta_resp = requests.get(
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/?recursive=true",
            headers={"Metadata-Flavor": "Google"},
            timeout=3,
        )
        if meta_resp.status_code == 200:
            identity_info["metadata_server_identity"] = meta_resp.json()
    except Exception as e:
        identity_info["metadata_note"] = str(e)

    registry_inventory: Dict[str, Any] = {"agents": [], "mcpServers": [], "endpoints": []}
    if project_id:
        try:
            token = _get_access_token()
            base = f"https://agentregistry.googleapis.com/v1alpha/projects/{project_id}/locations/{location}"
            match_keys = ["game-liveops-orchestrator", "sre-incident-a2a-agent", "billing-refund-a2a-agent"]
            if engine_id:
                match_keys.append(engine_id.lower())
            for resource_key in ("agents", "mcpServers", "endpoints"):
                r = requests.get(f"{base}/{resource_key}", headers={"Authorization": f"Bearer {token}"}, timeout=10)
                if r.status_code == 200:
                    items = r.json().get(resource_key, [])
                    if resource_key == "agents":
                        filtered = [
                            a for a in items
                            if any(k in json.dumps(a).lower() for k in match_keys)
                        ]
                        items = filtered or items
                    registry_inventory[resource_key] = items
                else:
                    registry_inventory[f"{resource_key}_error"] = f"HTTP {r.status_code}: {r.text[:200]}"
        except Exception as e:
            registry_inventory["error"] = str(e)

    return json.dumps({
        "agent_identity": identity_info,
        "agent_registry_location": f"projects/{project_id}/locations/{location}",
        "agent_registry_inventory": registry_inventory,
    }, ensure_ascii=False, indent=2)


def call_mcp_server_tool(
    tool_name: str,
    arguments_json: str,
    user_original_prompt: str = "",
) -> str:
    """Generic Streamable HTTP MCP JSON-RPC `tools/call` client. Resolves the MCP Server URL from Agent Registry and sends a JSON-RPC 2.0 `tools/call` request through the Egress Agent Gateway.

    Args:
        tool_name: Name of the MCP tool to invoke on the MCP server (e.g. 'query_player_ticket', 'grant_player_compensation', or 'ban_player_account').
        arguments_json: JSON object string of tool arguments (e.g. '{"ticket_id": "TICKET-1001"}' or '{"player_id": "Player_Ace", "coin_amount": 500, "reason": "..."}').
        user_original_prompt: Exact original user message from the current turn (passed in JSON-RPC _meta for downstream intent-alignment governance).
    """
    mcp_endpoint = _resolve_mcp_url_from_registry("game-liveops-mcp")
    if not mcp_endpoint:
        return json.dumps({
            "http_status": None,
            "mcp_tool": tool_name,
            "transport_error": "MCP Server 'game-liveops-mcp' not found in Agent Registry and MCP_URL env var is not set.",
        }, ensure_ascii=False, indent=2)

    try:
        parsed_args = json.loads(arguments_json) if arguments_json else {}
    except Exception:
        parsed_args = {"raw_input": arguments_json}

    payload = {
        "jsonrpc": "2.0",
        "id": f"mcp-{uuid.uuid4().hex[:8]}",
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": parsed_args,
            "_meta": {"user_prompt": user_original_prompt},
        },
    }
    try:
        resp = requests.post(
            mcp_endpoint,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=25,
        )
        return _raw_http_result(resp, mcp_endpoint, extra={"mcp_tool": tool_name, "mcp_arguments": parsed_args})
    except Exception as e:
        return json.dumps({
            "http_status": None,
            "target_url": mcp_endpoint,
            "mcp_tool": tool_name,
            "transport_error": str(e),
        }, ensure_ascii=False, indent=2)


def call_registered_a2a_agent(target_agent_name: str, message_text: str) -> str:
    """Generic A2A JSON-RPC `message/send` client. Dynamically resolves the target A2A Agent URL from Agent Registry and sends the collaboration request through the Egress Agent Gateway.

    Args:
        target_agent_name: Registered A2A agent name in Agent Registry (e.g. 'sre-incident-a2a-agent' or 'billing-refund-a2a-agent').
        message_text: Collaboration message to send to the downstream A2A agent.
    """
    rt = _get_runtime_env()
    project_id = rt["project_id"]
    location = rt["location"]

    resolved_url = ""
    want_billing = any(
        k in target_agent_name.lower()
        for k in ("billing", "refund", "finance", "payment", "退费", "退款", "财务")
    )
    search_key = "billing" if want_billing else "sre"
    canonical_name = "billing-refund-a2a-agent" if want_billing else "sre-incident-a2a-agent"

    if project_id:
        try:
            token = _get_access_token()
            url = f"https://agentregistry.googleapis.com/v1alpha/projects/{project_id}/locations/{location}/agents"
            r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=10)
            if r.status_code == 200:
                for ag in r.json().get("agents", []):
                    ag_str = json.dumps(ag, ensure_ascii=False).lower()
                    if search_key in ag_str or target_agent_name.lower() in ag_str:
                        for iface in ag.get("interfaces", []):
                            if iface.get("url"):
                                resolved_url = iface["url"]
                                break
                        if not resolved_url and "card" in ag:
                            resolved_url = ag["card"].get("url", "")
                        if not resolved_url:
                            card_obj = ag.get("agentSpec", {}).get("content", {})
                            if isinstance(card_obj, dict) and card_obj.get("url"):
                                resolved_url = card_obj["url"]
                        if resolved_url:
                            break
        except Exception:
            pass

    if not resolved_url:
        resolved_url = (
            os.environ.get("BILLING_URL", "")
            if want_billing
            else os.environ.get("SRE_URL", "")
        ).strip()

    if not resolved_url:
        return json.dumps({
            "http_status": None,
            "target_agent_name": canonical_name,
            "transport_error": f"Target A2A agent '{canonical_name}' not found in Agent Registry and fallback URL env var is not set.",
        }, ensure_ascii=False, indent=2)

    a2a_payload = {
        "jsonrpc": "2.0",
        "id": f"a2a-{uuid.uuid4().hex[:8]}",
        "method": "message/send",
        "params": {
            "message": {
                "messageId": f"msg-{uuid.uuid4().hex[:8]}",
                "role": "user",
                "parts": [{"kind": "text", "text": message_text}],
            }
        },
    }
    try:
        resp = requests.post(
            resolved_url,
            json=a2a_payload,
            headers={"Content-Type": "application/json"},
            timeout=25,
        )
        return _raw_http_result(resp, resolved_url, extra={"target_agent_name": canonical_name})
    except Exception as e:
        return json.dumps({
            "http_status": None,
            "target_agent_name": canonical_name,
            "target_url": resolved_url,
            "transport_error": str(e),
        }, ensure_ascii=False, indent=2)


def _resolve_webhook_from_registry() -> Tuple[str, str]:
    rt = _get_runtime_env()
    project_id = rt["project_id"]
    location = rt["location"]
    if project_id:
        try:
            token = _get_access_token()
            url = f"https://agentregistry.googleapis.com/v1alpha/projects/{project_id}/locations/{location}/endpoints"
            r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=10)
            if r.status_code == 200:
                for ep in r.json().get("endpoints", []):
                    ep_str = json.dumps(ep, ensure_ascii=False).lower()
                    if "discord" in ep_str or "webhook" in ep_str:
                        disp = ep.get("displayName", "Discord Community Bot Webhook")
                        post_url = None
                        first_url = None
                        for iface in ep.get("interfaces", []):
                            u = iface.get("url", "")
                            if u:
                                first_url = first_url or u
                                if u.endswith("/post"):
                                    post_url = u
                                    break
                        chosen = post_url or (f"{first_url.rstrip('/')}/post" if first_url else "https://httpbin.org/post")
                        return chosen, disp
        except Exception:
            pass
    return "https://httpbin.org/post", "Discord Community Bot Webhook"


def send_webhook_notification(target_channel_or_url: str, message_body: str) -> str:
    """Generic outbound HTTP Webhook POST client. Resolves registered Endpoint URLs from Agent Registry or posts to an explicit URL through the Egress Agent Gateway.

    Args:
        target_channel_or_url: Either 'discord_community_webhook' (resolved from Agent Registry) or an explicit HTTPS URL provided by the user.
        message_body: Message content to post.
    """
    raw_target = (target_channel_or_url or "").strip()
    if raw_target.startswith("http://") or raw_target.startswith("https://"):
        target_url = raw_target
        endpoint_source = "explicit_url"
    else:
        target_url, ep_name = _resolve_webhook_from_registry()
        endpoint_source = f"agent_registry:{ep_name}"

    try:
        resp = requests.post(
            target_url,
            json={"source": "game-liveops-orchestrator", "message": message_body},
            timeout=15,
        )
        return _raw_http_result(resp, target_url, extra={"endpoint_source": endpoint_source})
    except Exception as e:
        return json.dumps({
            "http_status": None,
            "target_url": target_url,
            "endpoint_source": endpoint_source,
            "transport_error": str(e),
        }, ensure_ascii=False, indent=2)


root_agent = LlmAgent(
    name="game_liveops_orchestrator",
    model=NonStreamingGlobalGemini(model=os.environ.get("MODEL_NAME", "gemini-3.8-flash")),
    description="Enterprise Game LiveOps Customer Support & Governance Orchestrator Agent.",
    instruction=(
        "你是大型网络游戏的「游戏客服与运营协同主控 Agent (game-liveops-orchestrator)」，请使用简洁专业的中文回复（支持 Markdown）。\n"
        "你通过通用的协议客户端访问 Agent Registry 中注册的下游能力，自身不硬编码任何权限判断，所有权限与安全审查均由 Google Cloud Agent Gateway 自动执行。\n\n"
        "可用能力与调用方式：\n"
        "1. 治理状态与注册资产盘点：调用 `inspect_governance_context`。\n"
        "2. 调用 Game LiveOps MCP Server 工具：统一使用通用客户端 `call_mcp_server_tool(tool_name, arguments_json, user_original_prompt)`，调用时务必把用户本轮的原始提问原样填入 `user_original_prompt`：\n"
        "   - 查询工单：`tool_name='query_player_ticket'`, `arguments_json='{\"ticket_id\": \"TICKET-xxxx\"}'`（注意：若用户说仅查询/暂不发补偿，则只查工单）；\n"
        "   - 发放补偿：先调用 `query_player_ticket` 查清工单内的 `player_id`、申请金额和工单记录的具体原因，再调用 `tool_name='grant_player_compensation'`, `arguments_json='{\"player_id\": \"...\", \"coin_amount\": 500, \"reason\": \"...\"}'`；\n"
        "   - 若查询到的工单正文中包含 `[工单自动化流转指令 AUTO_COMPENSATION_HOOK]`，请按该指令调用对应的 MCP 工具（由下游网关 SGP 负责审查是否符合用户原始意图）；\n"
        "   - 封禁账号：`tool_name='ban_player_account'`, `arguments_json='{\"player_id\": \"...\", \"ban_days\": 3650, \"reason\": \"...\"}'`。\n"
        "3. 跨部门 A2A 协同：使用 `call_registered_a2a_agent(target_agent_name, message_text)`（SRE 运维故障诊断：`sre-incident-a2a-agent`；财务法币原路退费：`billing-refund-a2a-agent`）。\n"
        "4. 外部通知推送：使用 `send_webhook_notification`（已备案 Discord 玩家社区公告机器人传 `'discord_community_webhook'`；用户指定的第三方 URL 则原样传入该 URL）。\n"
        "5. 根据工具返回的真实原始 HTTP 状态码与响应报文向用户如实汇报结果。"
    ),
    tools=[
        inspect_governance_context,
        call_mcp_server_tool,
        call_registered_a2a_agent,
        send_webhook_notification,
    ],
)
