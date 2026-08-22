"""Signed audit receipt — proof is the product.

Every audit emits `perslis.invoice-audit-receipt.v3`: the exact input scan
hashes, the pricebook hash, the taught-rules hash, every line verdict, an
`expected` set of invariants, and an Ed25519 signature over the canonical JSON.
`verify` re-checks the signature, (when the files are present) re-hashes the
inputs, AND re-proves the invariants from the receipt's own numbers — a receipt
is re-runnable, self-proving evidence, not a claim. Keys live at
~/.invoice-audit/ (0600), generated on first use.

Signing backend: prefer `cryptography` (OpenSSL, fast). Where its wheel is
unavailable — an offline Windows/ARM64 guest — fall back to a vendored pure
Python Ed25519. Both are standard RFC 8032, so a receipt signed under the pure
backend verifies under `cryptography` and vice-versa (proven by a host test).
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from .invariants import check_invariants
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

SCHEMA = "perslis.invoice-audit-receipt.v3"
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


def _recheck_file(obj, kind: str, problems: list, hashed: list | None = None) -> None:
    """Re-hash one referenced input, fail-closed with a NAMED reason. Tolerates a
    malformed (path-less / non-dict) entry — a verification must never crash into
    an unnamed traceback on a signed-but-malformed body; it emits a reason code.

    When `hashed` is provided, the path is appended as `(kind, path)` at the exact
    moment its bytes are read — the ONLY honest source of "what was re-hashed."
    A tampered file is still recorded (it WAS hashed; it just didn't match); an
    absent or malformed one never is (its bytes were never read)."""
    path = obj.get("path") if isinstance(obj, dict) else None
    if not path:
        problems.append(f"{kind}-malformed-no-path")
        return
    p = Path(path)
    if not p.exists():
        problems.append(f"{kind}-absent:{p.name}")
        return
    if hashed is not None:
        hashed.append((kind, path))
    if sha256_file(p) != (obj.get("sha256") if isinstance(obj, dict) else None):
        problems.append(f"{kind}-hash-changed:{p.name}")


def verify_receipt(receipt: dict, rehash_inputs: bool = True, *,
                   _hashed: list | None = None) -> list[str]:
    """Return list of named problems; empty list == verified.

    `_hashed` is an optional out-parameter: when a list is passed, it is filled
    with `(kind, path)` for every file whose bytes were ACTUALLY re-hashed —
    the single source of truth for provenance (see primitives._verify). It never
    changes the returned verdict; callers that only want the verdict ignore it."""
    problems: list[str] = []
    sig = receipt.get("signature")
    pub = receipt.get("publicKey")
    if not sig or not pub:
        return ["receipt-unsigned"]        # early return: nothing was hashed
    body = {k: v for k, v in receipt.items() if k not in ("signature", "publicKey")}
    if not _verify_sig(bytes.fromhex(pub), _canonical(body), bytes.fromhex(sig)):
        problems.append("receipt-signature-invalid")
    if rehash_inputs:
        for scan in receipt.get("scans", []):
            scan = scan if isinstance(scan, dict) else {}
            _recheck_file(scan, "scan", problems, _hashed)
            source_path = scan.get("source_path")
            source_sha256 = scan.get("source_sha256")
            if source_path and source_sha256:
                sp = Path(source_path)
                if not sp.exists():
                    problems.append(f"source-absent:{sp.name}")
                else:
                    if _hashed is not None:
                        _hashed.append(("source", source_path))
                    if sha256_file(sp) != source_sha256:
                        problems.append(f"source-hash-changed:{sp.name}")
        if receipt.get("pricebook"):
            _recheck_file(receipt["pricebook"], "pricebook", problems, _hashed)
        if receipt.get("marketPricebook"):
            _recheck_file(receipt["marketPricebook"], "market-pricebook", problems, _hashed)
        if receipt.get("marketBenchmarks"):
            _recheck_file(receipt["marketBenchmarks"], "market-benchmarks", problems, _hashed)
        if receipt.get("floorRules"):
            _recheck_file(receipt["floorRules"], "floor-rules", problems, _hashed)
    # Invariants hold, not just hashes match: re-prove the audit's own arithmetic
    # and policy verdicts from the receipt's recorded numbers. Independent of disk
    # (it reads the signed body), so it runs even with rehash off — a re-signed
    # tampered body passes the signature yet fails here.
    problems.extend(check_invariants(receipt))
    return problems
