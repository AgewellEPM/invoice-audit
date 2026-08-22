"""Invariants — the EXPECTED set a receipt must satisfy.

The keystone of the self-healing loop (docs/SELF_HEALING_LOOP.md). The symbolic
layer emits, as first-class signed data, the relations that MUST hold; `verify`
re-proves them from the receipt's own recorded numbers. That graduates
verification from "hashes and signature match" to "the audit's arithmetic and
policy verdicts are internally sound" — a *self-proving* receipt.

Why this matters: a signature proves the body is unchanged since signing. It does
NOT prove the body was ever internally consistent. Someone who edits a line total
AND re-signs passes the signature check; the invariant check catches them, because
the recorded verdict no longer matches a fresh deterministic recomputation.

Every check here is deterministic and fail-closed with a NAMED reason. No ML.
An invariant that references data the receipt no longer contains is a violation
(`invariant-unresolvable:*`), never a crash and never a silent pass.
"""
from __future__ import annotations

INVARIANTS_VERSION = "invoice-audit.invariants.v1"

# Matches validate.CENT / grounding.CENT — the half-cent float tolerance. Kept
# local so the invariant re-evaluation never drifts from the gate that produced
# the numbers; if that tolerance ever changes, it changes in lockstep here.
CENT = 0.005


# ── declaration (audit time) ──────────────────────────────────────────────────

def build_invariants(invoices: list[dict]) -> list[dict]:
    """Emit the invariant declarations for a set of audited invoices. Pure record
    of relations that must hold — the operands are re-read from the receipt at
    verify time, so nothing here is a second copy that could silently diverge
    (the one exception is the floor `bound`, the taught max, which IS part of the
    EXPECTED policy and so is declared explicitly)."""
    out: list[dict] = []
    for inv in invoices:
        file = inv.get("file")
        # One per line: the recorded arithmetic verdict must match recomputation.
        for i, _line in enumerate(inv.get("lines", [])):
            out.append({
                "id": f"line-arithmetic:{file}:{i}",
                "kind": "line-arithmetic",
                "scope": {"invoice": file, "line": i},
                "statement": "an arithmetic-mismatch flag exists for this line "
                             "iff line_total != round(qty * unit_price, 2)",
            })
            # One per line that a taught max_unit_price rule actually vetoed.
            bound = _recorded_floor_max(_line)
            if bound is not None:
                out.append({
                    "id": f"floor-max-unit-price:{file}:{i}",
                    "kind": "floor-max-unit-price",
                    "scope": {"invoice": file, "line": i},
                    "bound": bound[0],
                    "source": bound[1],
                    "statement": "unit_price exceeds the taught max iff a "
                                 "floor-veto is recorded for this line",
                })
        # One per invoice: the recorded reconcile verdict must match recomputation.
        out.append({
            "id": f"invoice-reconcile:{file}",
            "kind": "invoice-reconcile",
            "scope": {"invoice": file},
            "statement": "statedTotalReconciles == (stated_total present and "
                         "round(sum(line_total), 2) within a cent of it)",
        })
    return out


# ── re-evaluation (verify time) ───────────────────────────────────────────────

def check_invariants(receipt: dict) -> list[str]:
    """Re-prove every declared invariant against the receipt's recorded numbers.
    Returns named problems; empty == all invariants hold. Never raises: a
    malformed/absent reference fails closed to `invariant-unresolvable:<id>`."""
    problems: list[str] = []
    if not isinstance(receipt, dict):
        return ["invariant-unresolvable:receipt-not-a-dict"]
    declared = receipt.get("expected")
    if not declared:
        return problems  # no EXPECTED block → nothing to prove (older schema)
    by_file = {inv.get("file"): inv
               for inv in receipt.get("invoices", []) if isinstance(inv, dict)}

    for decl in declared if isinstance(declared, list) else []:
        if not isinstance(decl, dict):
            problems.append("invariant-unresolvable:malformed-declaration")
            continue
        inv = by_file.get((decl.get("scope") or {}).get("invoice"))
        if inv is None:
            problems.append(f"invariant-unresolvable:{decl.get('id')}")
            continue
        kind = decl.get("kind")
        if kind == "line-arithmetic":
            _check_line_arithmetic(decl, inv, problems)
        elif kind == "floor-max-unit-price":
            _check_floor_max(decl, inv, problems)
        elif kind == "invoice-reconcile":
            _check_invoice_reconcile(decl, inv, problems)
        else:
            problems.append(f"invariant-unresolvable:{decl.get('id')}")
    return problems


def _check_line_arithmetic(decl: dict, inv: dict, problems: list) -> None:
    line = _line_at(inv, decl)
    if line is None:
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    idx = decl["scope"]["line"]
    try:
        computed_ok = abs(round(_f(line["qty"]) * _f(line["unit_price"]), 2)
                          - _f(line["line_total"])) <= CENT
    except (KeyError, TypeError, ValueError):
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    flagged = _has_flag(inv, "arithmetic-mismatch", idx)
    # The recorded verdict (a flag) must agree with the fresh recomputation.
    if computed_ok == flagged:
        problems.append(f"invariant-violated:{decl.get('id')}")


def _check_floor_max(decl: dict, inv: dict, problems: list) -> None:
    line = _line_at(inv, decl)
    if line is None:
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    idx = decl["scope"]["line"]
    try:
        exceeds = _f(line["unit_price"]) > _f(decl["bound"]) + CENT
    except (KeyError, TypeError, ValueError):
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    vetoed = _has_flag(inv, "floor-veto", idx)
    # A floor-veto is recorded iff the unit price actually exceeds the taught max.
    if exceeds != vetoed:
        problems.append(f"invariant-violated:{decl.get('id')}")


def _check_invoice_reconcile(decl: dict, inv: dict, problems: list) -> None:
    try:
        stated = inv.get("stated_total")
        lines = inv.get("lines", [])
        if stated is None:
            computed = False
        else:
            computed = abs(round(sum(_f(l["line_total"]) for l in lines), 2)
                           - _f(stated)) <= CENT
    except (KeyError, TypeError, ValueError):
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    recorded = inv.get("statedTotalReconciles")
    if bool(recorded) != computed:
        problems.append(f"invariant-violated:{decl.get('id')}")


# ── small helpers ─────────────────────────────────────────────────────────────

def _f(x) -> float:
    """Coerce a recorded number, rejecting bool (True/False are not money)."""
    if isinstance(x, bool):
        raise ValueError("bool is not a number")
    return float(x)


def _line_at(inv: dict, decl: dict):
    idx = (decl.get("scope") or {}).get("line")
    lines = inv.get("lines", [])
    if not isinstance(idx, int) or not isinstance(lines, list) or not (0 <= idx < len(lines)):
        return None
    line = lines[idx]
    return line if isinstance(line, dict) else None


def _has_flag(inv: dict, kind: str, line_idx: int) -> bool:
    for f in inv.get("flags", []) or []:
        if isinstance(f, dict) and f.get("kind") == kind and f.get("line") == line_idx:
            return True
    return False


def _recorded_floor_max(line: dict):
    """Return (max_value, source) if this line has a taught max_unit_price veto
    recorded, else None. The bound is only present on lines the floor vetoed —
    a known limit: clean lines carry no floor invariant (see the doc)."""
    floor = line.get("floor") if isinstance(line, dict) else None
    for c in (floor or {}).get("conflicts", []) or []:
        if isinstance(c, dict) and c.get("relation_type") == "max_unit_price":
            try:
                return (float(c["object"]), c.get("source"))
            except (KeyError, TypeError, ValueError):
                return None
    return None
