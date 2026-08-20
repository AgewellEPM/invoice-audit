"""Continuous audit watcher.

The production shape is a long-running worker. The testable core is a single
"run if inputs changed" function keyed by source-file hashes.
"""
from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

from .audit import audit_folder
from .ingest import SCAN_EXTS
from .ocr import AuditError, sha256_file
from .store import connect, store_receipt


def source_fingerprint(
    scans_dir: Path,
    pricebook_path: Path,
    floor_path: Path | None = None,
) -> str:
    if not scans_dir.is_dir():
        raise AuditError(f"scans-dir-missing:{scans_dir}")
    files = []
    for p in sorted(scans_dir.iterdir()):
        if p.suffix.lower() not in SCAN_EXTS:
            continue
        files.append(_file_fingerprint("scan", p))
    files.append(_file_fingerprint("pricebook", pricebook_path))
    if floor_path is not None:
        files.append(_file_fingerprint("rules", floor_path))
    raw = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def run_once_if_changed(
    scans_dir: Path,
    pricebook_path: Path,
    db_path: Path,
    *,
    floor_path: Path | None = None,
    state_path: Path | None = None,
    receipt_path: Path | None = None,
    tolerance: float = 0.15,
) -> dict:
    state_path = state_path or db_path.with_suffix(".watch-state.json")
    fingerprint = source_fingerprint(scans_dir, pricebook_path, floor_path)
    old = _read_state(state_path)
    if old.get("fingerprint") == fingerprint:
        return {"changed": False, "fingerprint": fingerprint,
                "reason": "inputs-unchanged"}

    receipt = audit_folder(
        scans_dir,
        pricebook_path,
        tolerance=tolerance,
        floor_path=floor_path,
    )
    if receipt_path is not None:
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True))

    with connect(db_path) as con:
        receipt_id = store_receipt(con, receipt)

    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({
        "fingerprint": fingerprint,
        "receipt_id": receipt_id,
        "generatedAt": receipt.get("generatedAt"),
        "db": str(db_path),
        "receipt": str(receipt_path) if receipt_path else None,
    }, indent=2, sort_keys=True))
    return {
        "changed": True,
        "fingerprint": fingerprint,
        "receipt_id": receipt_id,
        "totals": receipt.get("totals", {}),
    }


def watch_loop(
    scans_dir: Path,
    pricebook_path: Path,
    db_path: Path,
    *,
    floor_path: Path | None = None,
    state_path: Path | None = None,
    receipt_path: Path | None = None,
    tolerance: float = 0.15,
    interval: float = 30.0,
) -> None:
    while True:
        result = run_once_if_changed(
            scans_dir,
            pricebook_path,
            db_path,
            floor_path=floor_path,
            state_path=state_path,
            receipt_path=receipt_path,
            tolerance=tolerance,
        )
        if result["changed"]:
            totals = result.get("totals", {})
            print(
                "changed: "
                f"invoices={totals.get('invoices', 0)} "
                f"flagged={totals.get('flagged', 0)} "
                f"receipt_id={result.get('receipt_id')}",
                flush=True,
            )
        else:
            print("unchanged", flush=True)
        time.sleep(interval)


def _file_fingerprint(kind: str, path: Path) -> dict:
    if not path.exists():
        raise AuditError(f"{kind}-missing:{path}")
    st = path.stat()
    return {
        "kind": kind,
        "path": str(path),
        "size": st.st_size,
        "sha256": sha256_file(path),
    }


def _read_state(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}
