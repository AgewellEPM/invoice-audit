"""The primitive registry — the tool-addressable substrate under the REPL.

Deliberately NOT clever: no plugin system, no dynamic dispatch, no taxonomy.
Just enough to identify each operation by `name`, `permission`, `input_schema`,
`output_schema`, and `implementation` — so the CLI, the Swift app, and (later)
the REPL all consume the SAME structured result instead of each re-deriving it.

This is step 2 of the doctrine's progression (functions → tool-addressable).
`verify` is the template: an existing deterministic operation standardized into
the shape the rest of the system will follow. See docs/FINANCIAL_DOCTRINE.md.
"""
from __future__ import annotations

import datetime
from dataclasses import dataclass, asdict
from enum import Enum
from pathlib import Path
from typing import Callable

from .receipt import verify_receipt


class Permission(str, Enum):
    """Capability tier. Enforced by handing a session only the primitives it may
    call — read-only sessions get READ tools only, so a misparsed intent cannot
    mutate. Authority lives here, never in the parse."""
    READ = "read"                # never mutates
    WRITE = "write"              # mutates non-money state
    MONEY_GATED = "money-gated"  # touches money → human gate required


@dataclass(frozen=True)
class Primitive:
    name: str
    permission: Permission
    input_schema: dict
    output_schema: dict
    implementation: Callable

    def __call__(self, *args, **kwargs):
        return self.implementation(*args, **kwargs)


# The whole registry. A plain dict on purpose — no magic.
REGISTRY: dict[str, "Primitive"] = {}


def register(p: "Primitive") -> "Primitive":
    if p.name in REGISTRY:
        raise ValueError(f"primitive-already-registered:{p.name}")
    REGISTRY[p.name] = p
    return p


def primitives(permission: Permission | None = None) -> list[str]:
    """Names of registered primitives, optionally filtered by permission tier.
    (Forward-looking hook for scoping a read-only REPL session.)"""
    return sorted(n for n, p in REGISTRY.items()
                  if permission is None or p.permission == permission)


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── verify ──────────────────────────────────────────────────────────────────
VERIFY_RULE_VERSION = "invoice-audit.verify.v1"


@dataclass(frozen=True)
class VerificationResult:
    """The one structured shape every surface narrates over. The categories are
    FIXED so CLI / Swift / REPL all read the same substrate, never ad-hoc text."""
    ok: bool
    problems: list[str]
    provenance: dict
    rule_version: str
    timestamp: str

    def to_dict(self) -> dict:
        return asdict(self)


def _safe_get(obj, key):
    """dict.get that tolerates a non-dict — provenance must never crash."""
    return obj.get(key) if isinstance(obj, dict) else None


def _entry_paths(entries, key):
    """Pull `key` from each entry, tolerating any shape (dict / str) so the
    provenance builder never raises on a malformed receipt."""
    out = []
    for e in entries if isinstance(entries, list) else []:
        if isinstance(e, dict):
            v = e.get(key)
            if v:
                out.append(v)
        elif isinstance(e, str) and key == "path":
            out.append(e)
    return out


def _was_hashed(path, kind: str, problems: list) -> bool:
    """True iff the core genuinely re-hashed this file — present and well-formed,
    i.e. no `{kind}-absent:<name>` and no `{kind}-malformed-no-path` was recorded.
    Provenance is derived from what actually ran, never from mere intent."""
    if not path or f"{kind}-malformed-no-path" in problems:
        return False
    return f"{kind}-absent:{Path(path).name}" not in problems


def _hashed_one(path, kind, problems):
    return path if _was_hashed(path, kind, problems) else None


def _hashed_list(paths, kind, problems):
    return [p for p in paths if _was_hashed(p, kind, problems)]


def _verify(receipt: dict, *, rehash_inputs: bool = True) -> VerificationResult:
    """READ-ONLY. Wraps the deterministic `receipt.verify_receipt` (the
    authoritative check, unchanged) into the standard result shape with
    provenance. It never raises where the core returns a verdict (a non-dict
    receipt fails closed identically to the core), and its provenance records
    only what the core actually executed — never more."""
    problems = verify_receipt(receipt, rehash_inputs=rehash_inputs)
    # Provenance is DERIVED from what verify_receipt actually did (the `problems`
    # tell us what was absent/malformed), not from the receipt's fields:
    #  - signatureChecked is true only if a signature check ran — an unsigned
    #    receipt short-circuits (`receipt-unsigned`) before any check.
    #  - reHashed lists only files GENUINELY re-hashed (present + well-formed),
    #    keyed by the same `path` the core hashes, and it includes the source
    #    files the core re-checks. Rehash off → reHashed is empty (nothing ran).
    signature_checked = "receipt-unsigned" not in problems
    provenance = {
        "schema": _safe_get(receipt, "schema"),
        "receiptGeneratedAt": _safe_get(receipt, "generatedAt"),
        "signatureChecked": signature_checked,
        "rehashedInputs": bool(rehash_inputs),
        "reHashed": {},
    }
    if rehash_inputs:
        scans = receipt.get("scans", []) if isinstance(receipt, dict) else []
        provenance["reHashed"] = {
            "scans": _hashed_list(_entry_paths(scans, "path"), "scan", problems),
            "sources": _hashed_list(_entry_paths(scans, "source_path"), "source", problems),
            "pricebook": _hashed_one(_safe_get(_safe_get(receipt, "pricebook"), "path"), "pricebook", problems),
            "marketPricebook": _hashed_one(_safe_get(_safe_get(receipt, "marketPricebook"), "path"), "market-pricebook", problems),
            "marketBenchmarks": _hashed_one(_safe_get(_safe_get(receipt, "marketBenchmarks"), "path"), "market-benchmarks", problems),
            "floorRules": _hashed_one(_safe_get(_safe_get(receipt, "floorRules"), "path"), "floor-rules", problems),
        }
    return VerificationResult(
        ok=(len(problems) == 0),
        problems=problems,
        provenance=provenance,
        rule_version=VERIFY_RULE_VERSION,
        timestamp=_now_iso(),
    )


verify = register(Primitive(
    name="verify",
    permission=Permission.READ,
    input_schema={
        "receipt": "object — a signed audit receipt",
        "rehash_inputs": "bool — re-hash source files (default true)",
    },
    output_schema={
        "ok": "bool",
        "problems": "string[] — named reason codes, empty when ok",
        "provenance": "object — what was checked, against what",
        "rule_version": "string",
        "timestamp": "string — iso8601 (when checked; metadata, not authority)",
    },
    implementation=_verify,
))
