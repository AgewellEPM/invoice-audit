"""Signed audit receipt — proof is the product.

Every audit emits `perslis.invoice-audit-receipt.v1`: the exact input scan
hashes, the pricebook hash, every line verdict, and an Ed25519 signature
over the canonical JSON. `verify` re-checks the signature and (when the
files are present) re-hashes the inputs — a receipt is re-runnable evidence,
not a claim. Keys live at ~/.invoice-audit/ (0600), generated on first use.
"""
from __future__ import annotations

import json
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey, Ed25519PublicKey)
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, PublicFormat)

from .ocr import AuditError, sha256_file

SCHEMA = "perslis.invoice-audit-receipt.v1"
KEY_DIR = Path.home() / ".invoice-audit"


def _canonical(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def _load_or_create_key() -> Ed25519PrivateKey:
    KEY_DIR.mkdir(mode=0o700, exist_ok=True)
    key_path = KEY_DIR / "signing.key"
    if key_path.exists():
        return Ed25519PrivateKey.from_private_bytes(key_path.read_bytes())
    key = Ed25519PrivateKey.generate()
    raw = key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    key_path.touch(mode=0o600)
    key_path.write_bytes(raw)
    return key


def sign_receipt(body: dict) -> dict:
    if body.get("schema") != SCHEMA:
        raise AuditError(f"receipt-wrong-schema:{body.get('schema')}")
    key = _load_or_create_key()
    pub = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    signature = key.sign(_canonical(body))
    return {**body, "publicKey": pub.hex(), "signature": signature.hex()}


def verify_receipt(receipt: dict, rehash_inputs: bool = True) -> list[str]:
    """Return list of named problems; empty list == verified."""
    problems: list[str] = []
    sig = receipt.get("signature")
    pub = receipt.get("publicKey")
    if not sig or not pub:
        return ["receipt-unsigned"]
    body = {k: v for k, v in receipt.items() if k not in ("signature", "publicKey")}
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(pub)).verify(
            bytes.fromhex(sig), _canonical(body))
    except Exception:
        problems.append("receipt-signature-invalid")
    if rehash_inputs:
        for scan in receipt.get("scans", []):
            p = Path(scan["path"])
            if not p.exists():
                problems.append(f"scan-absent:{p.name}")
            elif sha256_file(p) != scan["sha256"]:
                problems.append(f"scan-hash-changed:{p.name}")
        pb = receipt.get("pricebook", {})
        if pb:
            p = Path(pb["path"])
            if not p.exists():
                problems.append(f"pricebook-absent:{p.name}")
            elif sha256_file(p) != pb["sha256"]:
                problems.append(f"pricebook-hash-changed:{p.name}")
    return problems
