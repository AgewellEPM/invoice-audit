"""Local Kist/Perslis/VM bridge discovery for legacy source extraction.

This module is deliberately factual: it checks the real Kist Work Agent VM-stage
HTTP endpoints when present, and it inspects the local process table for the
Perslis/RM/QEMU pieces that do not currently expose a stable JSON status API.
"""
from __future__ import annotations

import json
import re
import subprocess
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any


DEFAULT_BRIDGE_URL = "http://127.0.0.1:8765"

_QMP_RE = re.compile(r"-qmp\s+unix:([^,\s]+)")
_NAME_RE = re.compile(r"-name\s+([^,\s]+)")

_ROLE_LABELS = {
    "desktopVision": "Kist Work Agent",
    "kistRuntime": "Kist runtime",
    "perslisBridge": "Perslis Bridge",
    "perslisRuntime": "Perslis runtime",
    "rmBridge": "RM bridge",
    "vmGuestMcp": "VM guest MCP",
    "win11Vm": "Win11 VM",
    "legacyWin95Vm": "Win95 legacy VM",
    "legacyWin98Vm": "Win98 legacy VM",
    "qemuVm": "QEMU VM",
}

_ROLE_PRIORITY = [
    "desktopVision",
    "perslisBridge",
    "perslisRuntime",
    "vmGuestMcp",
    "win11Vm",
    "legacyWin95Vm",
    "legacyWin98Vm",
    "kistRuntime",
    "qemuVm",
]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + path


def _http_json(base_url: str, path: str, timeout: float) -> dict[str, Any]:
    url = _url(base_url, path)
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read()
            text = body.decode("utf-8", errors="replace")
            try:
                payload: Any = json.loads(text)
            except json.JSONDecodeError:
                payload = {"raw": text[:1000]}
            return {
                "reachable": True,
                "status": int(getattr(response, "status", 0)),
                "url": url,
                "json": payload,
            }
    except urllib.error.HTTPError as e:
        return {
            "reachable": False,
            "status": e.code,
            "url": url,
            "error": f"HTTP {e.code}",
        }
    except Exception as e:  # pragma: no cover - depends on local service state.
        return {
            "reachable": False,
            "status": None,
            "url": url,
            "error": str(e),
        }


def _http_head(base_url: str, timeout: float) -> dict[str, Any]:
    url = base_url.rstrip("/") + "/"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return {
                "reachable": True,
                "status": int(getattr(response, "status", 0)),
                "url": url,
            }
    except urllib.error.HTTPError as e:
        return {
            "reachable": 200 <= e.code < 500,
            "status": e.code,
            "url": url,
            "error": f"HTTP {e.code}",
        }
    except Exception as e:  # pragma: no cover - depends on local service state.
        return {
            "reachable": False,
            "status": None,
            "url": url,
            "error": str(e),
        }


def _extract_qmp(command: str) -> str | None:
    match = _QMP_RE.search(command)
    return match.group(1) if match else None


def _extract_name(command: str) -> str | None:
    match = _NAME_RE.search(command)
    return match.group(1) if match else None


def _roles_for_command(command: str) -> list[str]:
    lower = command.lower()
    roles: list[str] = []

    if "desktop-vision-console" in lower and "server.py" in lower:
        roles.append("desktopVision")
    if ".kist/scripts/kist_runtime.py" in lower or "kist_runtime.py" in lower:
        roles.append("kistRuntime")
    if "perslis bridge/current/perslis-bridge" in lower or "/perslis bridge/" in lower:
        roles.append("perslisBridge")
    if (
        "perslis-agent-gateway" in lower
        or "perslis-headless" in lower
        or "perslis.app/contents" in lower
        or "perslisuniversal.app/contents" in lower
        or "perslisproofboard.app/contents" in lower
    ):
        roles.append("perslisRuntime")
    if (
        "vm_guest_mcp.py" in lower
        or "perslis-agent-gateway" in lower
        or "perslis-headless" in lower
    ):
        roles.append("rmBridge")
    if "vm_guest_mcp.py" in lower:
        roles.append("vmGuestMcp")
    if "qemu-system" in lower:
        if "ghostbridge-win11" in lower or "windows11" in lower or "win11" in lower:
            roles.append("win11Vm")
        elif "legacy-win95" in lower or "win95" in lower:
            roles.append("legacyWin95Vm")
        elif "legacy-win98" in lower or "ghostbridge-win98" in lower or "win98" in lower:
            roles.append("legacyWin98Vm")
        else:
            roles.append("qemuVm")

    return roles


def _primary_role(roles: list[str]) -> str:
    for role in _ROLE_PRIORITY:
        if role in roles:
            return role
    return roles[0]


def _parse_ps_line(line: str) -> tuple[int, str] | None:
    stripped = line.strip()
    if not stripped or stripped.upper().startswith("PID "):
        return None
    parts = stripped.split(maxsplit=1)
    if len(parts) != 2:
        return None
    try:
        return int(parts[0]), parts[1]
    except ValueError:
        return None


def summarize_processes(ps_text: str) -> dict[str, Any]:
    """Return process-role counts and safe previews from `ps -axo pid,command`."""
    items: list[dict[str, Any]] = []
    counts: dict[str, int] = {role: 0 for role in _ROLE_LABELS}

    for line in ps_text.splitlines():
        parsed = _parse_ps_line(line)
        if not parsed:
            continue
        pid, command = parsed
        roles = _roles_for_command(command)
        if not roles:
            continue
        for role in roles:
            counts[role] = counts.get(role, 0) + 1
        primary = _primary_role(roles)
        items.append({
            "pid": pid,
            "kind": primary,
            "label": _ROLE_LABELS.get(primary, primary),
            "roles": roles,
            "name": _extract_name(command),
            "qmpSocket": _extract_qmp(command),
            "commandPreview": command[:240],
        })

    return {
        "counts": {key: value for key, value in counts.items() if value},
        "items": items,
    }


def process_snapshot() -> dict[str, Any]:
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid,command"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except Exception as e:  # pragma: no cover - platform/local dependency.
        return {
            "ok": False,
            "error": str(e),
            "counts": {},
            "items": [],
        }
    summary = summarize_processes(result.stdout)
    summary["ok"] = result.returncode == 0
    if result.stderr:
        summary["error"] = result.stderr.strip()[:500]
    return summary


def _stage_summary(vm_stage: dict[str, Any]) -> dict[str, Any]:
    payload = vm_stage.get("json") if vm_stage.get("reachable") else {}
    payload = payload if isinstance(payload, dict) else {}
    stage = payload.get("vmStage") if isinstance(payload.get("vmStage"), dict) else {}
    return {
        "activeVmStage": bool(payload.get("active") and payload.get("ok")),
        "stageOs": stage.get("os"),
        "stageKind": stage.get("stageKind"),
        "readyHint": stage.get("readyHint"),
        "sessionUrl": stage.get("sessionUrl"),
        "qmpSocket": stage.get("qmpSocket") or stage.get("consoleQmpSocket"),
    }


def _scan_summary(vm_scan: dict[str, Any] | None) -> dict[str, Any]:
    if not vm_scan:
        return {
            "scanQueried": False,
            "scanOk": False,
            "elementCount": None,
            "safeMode": None,
        }
    payload = vm_scan.get("json") if vm_scan.get("reachable") else {}
    payload = payload if isinstance(payload, dict) else {}
    return {
        "scanQueried": True,
        "scanOk": bool(payload.get("ok")),
        "elementCount": payload.get("elementCount"),
        "safeMode": payload.get("safeMode"),
    }


def bridge_status(
    base_url: str = DEFAULT_BRIDGE_URL,
    *,
    include_scan: bool = False,
    timeout: float = 2.5,
) -> dict[str, Any]:
    console = _http_head(base_url, timeout=timeout)
    vm_stage = _http_json(base_url, "/api/vm-stage-status", timeout=timeout)
    vm_scan = (
        _http_json(base_url, "/api/vm-stage-scan", timeout=max(timeout, 8.0))
        if include_scan else None
    )
    processes = process_snapshot()

    counts = processes.get("counts", {})
    stage = _stage_summary(vm_stage)
    scan = _scan_summary(vm_scan)
    summary = {
        **stage,
        **scan,
        "desktopVision": bool(console.get("reachable") or counts.get("desktopVision")),
        "perslisRuntime": bool(counts.get("perslisRuntime") or counts.get("perslisBridge")),
        "perslisBridge": bool(counts.get("perslisBridge")),
        "rmBridge": bool(counts.get("rmBridge") or counts.get("vmGuestMcp")),
        "win11Vm": bool(counts.get("win11Vm")),
        "legacyVm": bool(counts.get("legacyWin95Vm") or counts.get("legacyWin98Vm")),
    }
    return {
        "ok": bool(summary["desktopVision"] or summary["activeVmStage"]),
        "checkedAt": _now(),
        "baseUrl": base_url.rstrip("/"),
        "console": console,
        "vmStage": vm_stage,
        "vmScan": vm_scan,
        "processes": processes,
        "summary": summary,
    }


def legacy_status_text(status: dict[str, Any]) -> str:
    summary = status.get("summary", {})
    lines = [
        f"Kist Work Agent: {'reachable' if summary.get('desktopVision') else 'not detected'}",
        f"Perslis runtime: {'detected' if summary.get('perslisRuntime') else 'not detected'}",
        f"RM bridge: {'detected' if summary.get('rmBridge') else 'not detected'}",
        f"Win11 VM: {'detected' if summary.get('win11Vm') else 'not detected'}",
        f"Legacy VM: {'detected' if summary.get('legacyVm') else 'not detected'}",
    ]
    if summary.get("activeVmStage"):
        parts = [
            "VM stage: active",
            str(summary.get("stageOs") or "unknown-os"),
            str(summary.get("stageKind") or "unknown-kind"),
        ]
        if summary.get("qmpSocket"):
            parts.append(str(summary["qmpSocket"]))
        lines.append(" · ".join(parts))
    else:
        lines.append("VM stage: not active")
    if summary.get("scanQueried"):
        safe = summary.get("safeMode")
        safe_text = "safe mode unknown" if safe is None else f"safe mode {'on' if safe else 'off'}"
        lines.append(
            f"Vision scan: {'ok' if summary.get('scanOk') else 'not ok'} · "
            f"{summary.get('elementCount')} elements · {safe_text}"
        )
    return "\n".join(lines)
