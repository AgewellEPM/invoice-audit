"""Inbound source connectors for nontechnical setup.

The connector layer turns "where is the data?" into a managed local workspace
that the audit engine already understands: scans folder, pricebook file, and
optional rules file. Native ERP integrations can plug in later; today the safe
generic paths are local/network folders, mbox exports, and API/Zapier JSON.
"""
from __future__ import annotations

import base64
import json
import mailbox
import re
import shutil
import urllib.request
from dataclasses import dataclass
from email.message import Message
from pathlib import Path
from urllib.parse import urlparse

from .ingest import SCAN_EXTS
from .ocr import AuditError, sha256_file


PRICE_EXTS = {".csv", ".sqlite", ".sqlite3", ".db"}
RULE_EXTS = {".json"}
READY_KINDS = {"local-folder", "network-folder", "email-mbox", "api-json"}
PRESET_KINDS = READY_KINDS | {"zapier", "quickbooks", "netsuite", "make"}


@dataclass(frozen=True)
class ConnectorConfig:
    kind: str
    name: str
    invoices: str = ""
    pricebook: str = ""
    floor: str = ""
    url: str = ""
    token_env: str = ""
    mbox: str = ""


def connector_presets() -> list[dict]:
    return [
        {
            "kind": "local-folder",
            "label": "Local folder",
            "status": "ready",
            "description": "Pick a folder of PDFs/images plus CSV/SQLite price history.",
        },
        {
            "kind": "network-folder",
            "label": "Network/share folder",
            "status": "ready",
            "description": "Use the same folder picker after mounting SMB/SharePoint/Dropbox/etc.",
        },
        {
            "kind": "email-mbox",
            "label": "Email export",
            "status": "ready",
            "description": "Import invoice attachments from a mailbox .mbox export.",
        },
        {
            "kind": "api-json",
            "label": "Generic API",
            "status": "ready",
            "description": "Pull invoice files and price data from simple JSON over HTTPS.",
        },
        {
            "kind": "zapier",
            "label": "Zapier / Make",
            "status": "via-api-json",
            "description": "Use a no-code automation to expose the generic API JSON shape.",
        },
        {
            "kind": "quickbooks",
            "label": "QuickBooks",
            "status": "via-zapier-or-api",
            "description": "Use Zapier/API export now; native OAuth can be added later.",
        },
        {
            "kind": "netsuite",
            "label": "NetSuite",
            "status": "via-zapier-or-api",
            "description": "Use SuiteTalk/Zapier/API JSON now; native OAuth can be added later.",
        },
    ]


def write_connector_config(config: ConnectorConfig, out_path: Path) -> Path:
    if config.kind not in PRESET_KINDS:
        raise AuditError(f"connector-unsupported-kind:{config.kind}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({
        "schema": "invoice-audit.connector.v1",
        "kind": config.kind,
        "name": config.name or config.kind,
        "invoices": config.invoices,
        "pricebook": config.pricebook,
        "floor": config.floor,
        "url": config.url,
        "token_env": config.token_env,
        "mbox": config.mbox,
    }, indent=2, sort_keys=True))
    return out_path


def load_connector_config(path: Path) -> ConnectorConfig:
    data = json.loads(path.read_text())
    kind = str(data.get("kind", ""))
    if kind not in PRESET_KINDS:
        raise AuditError(f"connector-unsupported-kind:{kind}")
    return ConnectorConfig(
        kind=kind,
        name=str(data.get("name", kind)),
        invoices=str(data.get("invoices", "")),
        pricebook=str(data.get("pricebook", "")),
        floor=str(data.get("floor", "")),
        url=str(data.get("url", "")),
        token_env=str(data.get("token_env", "")),
        mbox=str(data.get("mbox", "")),
    )


def sync_connector(config_path: Path, workspace: Path) -> dict:
    config = load_connector_config(config_path)
    target = workspace / _slug(config.name or config.kind)
    scans_dir = target / "scans"
    scans_dir.mkdir(parents=True, exist_ok=True)
    warnings: list[str] = []

    if config.kind in {"local-folder", "network-folder"}:
        pricebook, floor, copied = _sync_folder(config, target, scans_dir)
    elif config.kind == "email-mbox":
        pricebook, floor, copied = _sync_mbox(config, target, scans_dir)
    elif config.kind in {"api-json", "zapier", "quickbooks", "netsuite", "make"}:
        if not config.url:
            raise AuditError(f"connector-url-required:{config.kind}")
        pricebook, floor, copied = _sync_api_json(config, target, scans_dir)
    else:
        raise AuditError(f"connector-unsupported-kind:{config.kind}")

    if pricebook is None:
        if config.pricebook:
            pricebook = _copy_file(Path(config.pricebook), target / Path(config.pricebook).name)
        else:
            raise AuditError("connector-pricebook-missing")
    if floor is None and config.floor:
        floor = _copy_file(Path(config.floor), target / Path(config.floor).name)

    manifest = {
        "schema": "invoice-audit.connector-sync.v1",
        "connector": {
            "kind": config.kind,
            "name": config.name,
        },
        "scans_dir": str(scans_dir),
        "pricebook": str(pricebook),
        "floor": str(floor) if floor else "",
        "files": copied,
        "warnings": warnings,
    }
    manifest["files"].sort(key=lambda f: (f["role"], f["name"]))
    manifest_path = target / "sync-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True))
    manifest["manifest"] = str(manifest_path)
    return manifest


def _sync_folder(
    config: ConnectorConfig,
    target: Path,
    scans_dir: Path,
) -> tuple[Path | None, Path | None, list[dict]]:
    if not config.invoices:
        raise AuditError("connector-invoices-folder-required")
    source = Path(config.invoices)
    if not source.is_dir():
        raise AuditError(f"connector-invoices-folder-missing:{source}")
    copied: list[dict] = []
    for src in sorted(source.iterdir()):
        suffix = src.suffix.lower()
        if suffix in SCAN_EXTS:
            dst = _copy_file(src, scans_dir / src.name)
            copied.append(_file_record("invoice", dst))
    if not copied:
        raise AuditError(f"connector-no-invoice-files:{source}")
    pricebook = _copy_file(Path(config.pricebook), target / Path(config.pricebook).name) if config.pricebook else None
    floor = _copy_file(Path(config.floor), target / Path(config.floor).name) if config.floor else None
    if pricebook:
        copied.append(_file_record("pricebook", pricebook))
    if floor:
        copied.append(_file_record("rules", floor))
    return pricebook, floor, copied


def _sync_mbox(
    config: ConnectorConfig,
    target: Path,
    scans_dir: Path,
) -> tuple[Path | None, Path | None, list[dict]]:
    if not config.mbox:
        raise AuditError("connector-mbox-required")
    mbox_path = Path(config.mbox)
    if not mbox_path.exists():
        raise AuditError(f"connector-mbox-missing:{mbox_path}")
    box = mailbox.mbox(mbox_path)
    copied: list[dict] = []
    pricebook: Path | None = None
    floor: Path | None = None
    for message in box:
        for attachment in _attachments(message):
            filename = _safe_filename(attachment.get_filename() or "attachment.bin")
            payload = attachment.get_payload(decode=True) or b""
            suffix = Path(filename).suffix.lower()
            if suffix in SCAN_EXTS:
                dst = scans_dir / filename
                dst.write_bytes(payload)
                copied.append(_file_record("invoice", dst))
            elif suffix in PRICE_EXTS and pricebook is None:
                pricebook = target / filename
                pricebook.write_bytes(payload)
                copied.append(_file_record("pricebook", pricebook))
            elif suffix in RULE_EXTS and floor is None:
                floor = target / filename
                floor.write_bytes(payload)
                copied.append(_file_record("rules", floor))
    if not copied:
        raise AuditError(f"connector-mbox-no-attachments:{mbox_path}")
    return pricebook, floor, copied


def _sync_api_json(
    config: ConnectorConfig,
    target: Path,
    scans_dir: Path,
) -> tuple[Path | None, Path | None, list[dict]]:
    payload = _fetch_json(config.url)
    copied: list[dict] = []
    pricebook: Path | None = None
    floor: Path | None = None

    for item in payload.get("files", []):
        name = _safe_filename(str(item.get("name", "file.bin")))
        role = str(item.get("role", "")).lower()
        data = _file_payload(item)
        suffix = Path(name).suffix.lower()
        if role == "invoice" or suffix in SCAN_EXTS:
            dst = scans_dir / name
            dst.write_bytes(data)
            copied.append(_file_record("invoice", dst))
        elif role == "pricebook" or suffix in PRICE_EXTS:
            pricebook = target / name
            pricebook.write_bytes(data)
            copied.append(_file_record("pricebook", pricebook))
        elif role in {"rules", "floor"} or suffix in RULE_EXTS:
            floor = target / name
            floor.write_bytes(data)
            copied.append(_file_record("rules", floor))

    if payload.get("pricebook_csv") and pricebook is None:
        pricebook = target / "pricebook.csv"
        pricebook.write_text(str(payload["pricebook_csv"]))
        copied.append(_file_record("pricebook", pricebook))
    if payload.get("rules_json") and floor is None:
        floor = target / "floor-rules.json"
        floor.write_text(json.dumps(payload["rules_json"], indent=2, sort_keys=True))
        copied.append(_file_record("rules", floor))

    if not any(f["role"] == "invoice" for f in copied):
        raise AuditError("connector-api-no-invoice-files")
    return pricebook, floor, copied


def _attachments(message: Message):
    if message.is_multipart():
        for part in message.walk():
            if part.get_content_disposition() == "attachment":
                yield part
    elif message.get_filename():
        yield message


def _fetch_json(url: str) -> dict:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https", "file"}:
        raise AuditError("connector-api-url-must-be-http-https-or-file")
    with urllib.request.urlopen(url, timeout=20) as resp:
        data = resp.read()
    return json.loads(data.decode("utf-8"))


def _file_payload(item: dict) -> bytes:
    if "content_base64" in item:
        return base64.b64decode(str(item["content_base64"]))
    if "text" in item:
        return str(item["text"]).encode("utf-8")
    raise AuditError(f"connector-file-missing-content:{item.get('name', '')}")


def _copy_file(src: Path, dst: Path) -> Path:
    if not src.exists():
        raise AuditError(f"connector-file-missing:{src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.resolve() != dst.resolve():
        shutil.copy2(src, dst)
    return dst


def _file_record(role: str, path: Path) -> dict:
    return {
        "role": role,
        "name": path.name,
        "path": str(path),
        "sha256": sha256_file(path),
    }


def _safe_filename(value: str) -> str:
    name = Path(value).name
    return re.sub(r"[^A-Za-z0-9._ -]+", "-", name).strip() or "file.bin"


def _slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "connector"
