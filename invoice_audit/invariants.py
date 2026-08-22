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
Three failure shapes, never a crash and never a silent pass:
  invariant-violated:<id>      — recomputation disagrees with the recorded verdict
  invariant-unresolvable:<id>  — the receipt no longer holds the data to re-prove
  invariant-missing:<...>      — a current-schema receipt is missing a declaration
                                 it must carry (defends against a stripped block)
"""
from __future__ import annotations

INVARIANTS_VERSION = "invoice-audit.invariants.v1"

# Matches validate.CENT / grounding.CENT — the half-cent float tolerance. Kept
# local so the invariant re-evaluation never drifts from the gate that produced
# the numbers; if that tolerance ever changes, it changes in lockstep here.
CENT = 0.005

# Receipt schemas that MUST carry an `expected` block. A receipt claiming one of
# these but lacking invariants has been stripped — fail closed, don't wave it
# through as if it were an older (pre-invariants) receipt. Declared locally to
# avoid a receipt<->invariants import cycle; keep in sync with receipt.SCHEMA.
_INVARIANT_SCHEMAS = frozenset({"perslis.invoice-audit-receipt.v3"})


# ── declaration (audit time) ──────────────────────────────────────────────────

def build_invariants(invoices: list[dict]) -> list[dict]:
    """Emit the invariant declarations for a set of audited invoices. Pure record
    of relations that must hold — line operands are re-read from the receipt at
    verify time (no second copy that could diverge). The floor `bound` IS declared
    explicitly: it is the taught policy max, part of EXPECTED, and is recorded for
    every line a max rule covers (pass or veto), not only vetoed lines."""
    out: list[dict] = []
    for inv in invoices:
        file = inv.get("file")
        for i, line in enumerate(inv.get("lines", [])):
            out.append({
                "id": f"line-arithmetic:{file}:{i}",
                "kind": "line-arithmetic",
                "scope": {"invoice": file, "line": i},
                "statement": "an arithmetic-mismatch flag exists for this line "
                             "iff line_total != round(qty * unit_price, 2)",
            })
            bound = _applied_floor_max(line)
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
    Returns named problems; empty == all invariants hold. Never raises: any
    malformed/absent/stripped reference fails closed to a named reason."""
    if not isinstance(receipt, dict):
        return ["invariant-unresolvable:receipt-not-a-dict"]
    problems: list[str] = []
    invoices = receipt.get("invoices")
    invoices = invoices if isinstance(invoices, list) else []
    # A current-schema receipt with audited content MUST carry invariants that
    # cover it. `requires` is False for a contentless receipt (nothing to prove)
    # and for older (pre-invariants) schemas. This is what stops a strip-and-
    # resign bypass while letting a genuinely empty receipt through.
    requires = receipt.get("schema") in _INVARIANT_SCHEMAS and bool(invoices)
    declared = receipt.get("expected")
    if declared is None:
        return ["invariant-missing:expected-block-absent"] if requires else []
    if not isinstance(declared, list):
        return ["invariant-unresolvable:expected-not-a-list"]

    by_file = {inv.get("file"): inv for inv in invoices if isinstance(inv, dict)}

    # Anti-strip: every invoice must be covered by a reconcile invariant and every
    # line by an arithmetic one. A removed declaration is a stripped invariant.
    if requires:
        _check_coverage(declared, invoices, problems)

    for decl in declared:
        if not isinstance(decl, dict):
            problems.append("invariant-unresolvable:malformed-declaration")
            continue
        scope = decl.get("scope")
        if not isinstance(scope, dict):
            problems.append(f"invariant-unresolvable:{decl.get('id')}")
            continue
        inv = by_file.get(scope.get("invoice"))
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


def _check_coverage(declared: list, invoices: list, problems: list) -> None:
    """Every invoice needs a reconcile invariant; every line an arithmetic one.
    A missing one means the block was stripped after audit — fail closed."""
    reconcile = set()
    arithmetic = set()
    for d in declared:
        if not isinstance(d, dict):
            continue
        scope = d.get("scope") if isinstance(d.get("scope"), dict) else {}
        if d.get("kind") == "invoice-reconcile":
            reconcile.add(scope.get("invoice"))
        elif d.get("kind") == "line-arithmetic":
            arithmetic.add((scope.get("invoice"), scope.get("line")))
    for inv in invoices:
        if not isinstance(inv, dict):
            continue
        file = inv.get("file")
        if file not in reconcile:
            problems.append(f"invariant-missing:invoice-reconcile:{file}")
        lines = inv.get("lines")
        for i in range(len(lines) if isinstance(lines, list) else 0):
            if (file, i) not in arithmetic:
                problems.append(f"invariant-missing:line-arithmetic:{file}:{i}")


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
        # Strict `>`, matching the producer (floor._violation). No CENT band:
        # the floor vetoes on unit_price > cap exactly, so we must too or a veto
        # in the half-cent band would falsely (mis)match.
        exceeds = _f(line["unit_price"]) > _f(decl["bound"])
    except (KeyError, TypeError, ValueError):
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    vetoed = _has_flag(inv, "floor-veto", idx)
    # A floor-veto is recorded iff the unit price actually exceeds the taught max.
    if exceeds != vetoed:
        problems.append(f"invariant-violated:{decl.get('id')}")


def _check_invoice_reconcile(decl: dict, inv: dict, problems: list) -> None:
    recorded = inv.get("statedTotalReconciles")
    if not isinstance(recorded, bool):
        # A missing/malformed recorded verdict cannot be re-proven — fail closed
        # rather than let bool(None)==False silently pass a false recomputation.
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    try:
        stated = inv.get("stated_total")
        lines = inv.get("lines")
        lines = lines if isinstance(lines, list) else []
        if stated is None:
            computed = False
        else:
            computed = abs(round(sum(_f(l["line_total"]) for l in lines), 2)
                           - _f(stated)) <= CENT
    except (KeyError, TypeError, ValueError):
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    if recorded != computed:
        problems.append(f"invariant-violated:{decl.get('id')}")


# ── small helpers ─────────────────────────────────────────────────────────────

def _f(x) -> float:
    """Coerce a recorded number, rejecting bool (True/False are not money)."""
    if isinstance(x, bool):
        raise ValueError("bool is not a number")
    return float(x)


def _line_at(inv: dict, decl: dict):
    idx = (decl.get("scope") or {}).get("line")
    lines = inv.get("lines")
    if not isinstance(idx, int) or isinstance(idx, bool) or not isinstance(lines, list):
        return None
    if not (0 <= idx < len(lines)):
        return None
    line = lines[idx]
    return line if isinstance(line, dict) else None


def _has_flag(inv: dict, kind: str, line_idx: int) -> bool:
    flags = inv.get("flags")
    for f in flags if isinstance(flags, list) else []:
        if isinstance(f, dict) and f.get("kind") == kind and f.get("line") == line_idx:
            return True
    return False


def _applied_floor_max(line: dict):
    """Return (max_value, source) for the taught max that covers this line — from
    the floor's `appliedMaxUnitPrice`, which is recorded on passing lines too
    (floor.check_line), so coverage is complete. None when no max rule applied."""
    floor = line.get("floor") if isinstance(line, dict) else None
    field = (floor or {}).get("appliedMaxUnitPrice") if isinstance(floor, dict) else None
    if isinstance(field, dict):
        try:
            return (float(field["object"]), field.get("source"))
        except (KeyError, TypeError, ValueError):
            return None
    return None
