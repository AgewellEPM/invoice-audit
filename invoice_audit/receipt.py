"""Signed audit receipt — proof is the product.

Every audit emits `perslis.invoice-audit-receipt.v2`: the exact input scan
hashes, the pricebook hash, the taught-rules hash, every line verdict, and an
Ed25519 signature over the canonical JSON. `verify` re-checks the signature and
(when the files are present) re-hashes the inputs — a receipt is re-runnable
evidence, not a claim. Keys live at ~/.invoice-audit/ (0600), generated on
first use.

Signing backend: prefer `cryptography` (OpenSSL, fast). Where its wheel is
unavailable — an offline Windows/ARM64 guest — fall back to a vendored pure
Python Ed25519. Both are standard RFC 8032, so a receipt signed under the pure
backend verifies under `cryptography` and vice-versa (proven by a host test).
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from .ocr import AuditError, sha256_file

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey, Ed25519PublicKey)
    from cryptography.hazmat.primitives.serialization import (
        Encoding, NoEncryption, PrivateFormat, PublicFormat)
    HAVE_CRYPTOGRAPHY = True
except ImportError:  # no native wheel (e.g. Windows/ARM64 offline) — pure fallback
    from . import _ed25519_pure as _ed
    HAVE_CRYPTOGRAPHY = False

SCHEMA = "perslis.invoice-audit-receipt.v2"
KEY_DIR = Path.home() / ".invoice-audit"


def _canonical(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def _new_seed() -> bytes:
    """A fresh 32-byte Ed25519 seed (raw private key)."""
    if HAVE_CRYPTOGRAPHY:
        return Ed25519PrivateKey.generate().private_bytes(
            Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    return os.urandom(32)


def _load_or_create_seed() -> bytes:
    KEY_DIR.mkdir(mode=0o700, exist_ok=True)
    key_path = KEY_DIR / "signing.key"
    if key_path.exists():
        return key_path.read_bytes()
    seed = _new_seed()
    key_path.touch(mode=0o600)
    key_path.write_bytes(seed)
    return seed


def _sign(seed: bytes, msg: bytes) -> tuple[bytes, bytes]:
    """Return (public_key, signature) for msg under the 32-byte seed."""
    if HAVE_CRYPTOGRAPHY:
        key = Ed25519PrivateKey.from_private_bytes(seed)
        pub = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return pub, key.sign(msg)
    pub = _ed.publickey(seed)
    return pub, _ed.signature(msg, seed, pub)


def _verify_sig(pub: bytes, msg: bytes, sig: bytes) -> bool:
    if HAVE_CRYPTOGRAPHY:
        try:
            Ed25519PublicKey.from_public_bytes(pub).verify(sig, msg)
            return True
        except Exception:
            return False
    return _ed.checkvalid(sig, msg, pub)


def sign_receipt(body: dict) -> dict:
    if body.get("schema") != SCHEMA:
        raise AuditError(f"receipt-wrong-schema:{body.get('schema')}")
    seed = _load_or_create_seed()
    pub, signature = _sign(seed, _canonical(body))
    return {**body, "publicKey": pub.hex(), "signature": signature.hex()}


def verify_receipt(receipt: dict, rehash_inputs: bool = True) -> list[str]:
    """Return list of named problems; empty list == verified."""
    problems: list[str] = []
    sig = receipt.get("signature")
    pub = receipt.get("publicKey")
    if not sig or not pub:
        return ["receipt-unsigned"]
    body = {k: v for k, v in receipt.items() if k not in ("signature", "publicKey")}
    if not _verify_sig(bytes.fromhex(pub), _canonical(body), bytes.fromhex(sig)):
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
        fr = receipt.get("floorRules")
        if fr:
            p = Path(fr["path"])
            if not p.exists():
                problems.append(f"floor-rules-absent:{p.name}")
            elif sha256_file(p) != fr["sha256"]:
                problems.append(f"floor-rules-hash-changed:{p.name}")
    return problems
