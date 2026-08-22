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


# reHashed provenance categories, mapped from the core's internal `kind` codes.
# `single=True` categories can only reference one file, so they surface as a
# lone path (or None), not a list.
_REHASH_KINDS = [
    ("scans", "scan", False),
    ("sources", "source", False),
    ("pricebook", "pricebook", True),
    ("marketPricebook", "market-pricebook", True),
    ("marketBenchmarks", "market-benchmarks", True),
    ("floorRules", "floor-rules", True),
]


def _verify(receipt: dict, *, rehash_inputs: bool = True) -> VerificationResult:
    """READ-ONLY. Wraps the deterministic `receipt.verify_receipt` (the
    authoritative check, unchanged) into the standard result shape with
    provenance. It never raises where the core returns a verdict (a non-dict
    receipt fails closed identically to the core), and its provenance records
    ONLY files the core actually re-hashed — never more."""
    # `hashed` is filled BY the core, at the exact point each file's bytes are
    # read — so provenance can only ever report work that genuinely happened.
    # Not re-derived from the receipt or from reason codes: an unsigned receipt
    # short-circuits before any hashing and the list stays empty; an absent or
    # sha-less input is never appended; a tampered-but-present file IS (it was
    # hashed, it just didn't match). This is the single source of truth.
    hashed: list = []
    problems = verify_receipt(receipt, rehash_inputs=rehash_inputs, _hashed=hashed)
    # signatureChecked is true only if a signature check ran — an unsigned
    # receipt short-circuits (`receipt-unsigned`) before any check.
    signature_checked = "receipt-unsigned" not in problems
    by_kind: dict[str, list] = {}
    for kind, path in hashed:
        by_kind.setdefault(kind, []).append(path)
    # Invariants are re-proven by the core only once the receipt is signed (an
    # unsigned receipt short-circuits before them). `checked` is whether the core
    # got to re-evaluate them; `held` is whether they ALL held — never claimed
    # when any invariant-* problem was reported (no overclaim on a failure).
    declared = _safe_get(receipt, "expected")
    n_declared = len(declared) if isinstance(declared, list) else 0
    any_invariant_problem = any(p.startswith("invariant-") for p in problems)
    provenance = {
        "schema": _safe_get(receipt, "schema"),
        "receiptGeneratedAt": _safe_get(receipt, "generatedAt"),
        "signatureChecked": signature_checked,
        "rehashedInputs": bool(rehash_inputs),
        "reHashed": {},
        "invariants": {
            "version": _safe_get(receipt, "expectedVersion"),
            "declared": n_declared,
            "checked": signature_checked,
            "held": signature_checked and not any_invariant_problem,
        },
    }
    if rehash_inputs:
        provenance["reHashed"] = {
            key: ((by_kind.get(kind, [None])[0] if single
                   else by_kind.get(kind, [])))
            for key, kind, single in _REHASH_KINDS
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
