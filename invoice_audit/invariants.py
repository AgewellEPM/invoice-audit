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
    # Invoices are addressed POSITIONALLY (invoiceIndex), not by filename: a
    # filename is only a label and two distinct scans can legitimately share a
    # basename (e.g. page-001.png from two PDFs). The index is the invoice's stable
    # identity in the signed list, so no collision can mask or misroute a check.
    for idx, inv in enumerate(invoices):
        file = inv.get("file")
        for i, line in enumerate(inv.get("lines", [])):
            out.append({
                "id": f"line-arithmetic:{idx}:{i}",
                "kind": "line-arithmetic",
                "scope": {"invoiceIndex": idx, "invoice": file, "line": i},
                # The signed money operands, pinned. verify cross-checks them
                # against the line so a single-field tamper is caught even on an
                # already-flagged line (whose boolean verdict wouldn't move).
                "operands": {"qty": line.get("qty"),
                             "unit_price": line.get("unit_price"),
                             "line_total": line.get("line_total")},
                "statement": "line qty/unit/total match the pinned operands, and "
                             "an arithmetic-mismatch flag exists iff "
                             "line_total != round(qty * unit_price, 2)",
            })
            bound = _applied_floor_max(line)
            if bound is not None:
                out.append({
                    "id": f"floor-max-unit-price:{idx}:{i}",
                    "kind": "floor-max-unit-price",
                    "scope": {"invoiceIndex": idx, "invoice": file, "line": i},
                    "bound": bound[0],
                    "source": bound[1],
                    "statement": "unit_price exceeds the taught max iff a "
                                 "floor-veto is recorded for this line",
                })
        out.append({
            "id": f"invoice-reconcile:{idx}",
            "kind": "invoice-reconcile",
            "scope": {"invoiceIndex": idx, "invoice": file},
            "statedTotal": inv.get("stated_total"),   # pinned (may be null)
            "statement": "stated_total matches the pinned value, and "
                         "statedTotalReconciles == (stated_total present and "
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
    # A current-schema receipt that CLAIMS audited content MUST carry invariants
    # that cover it. Content is claimed by invoices, a review queue, OR non-zero
    # totals — so stripping `invoices` while keeping `totals` (which still asserts
    # findings) cannot dodge the requirement. `requires` is False only for a
    # genuinely vacuous receipt and for older (pre-invariants) schemas.
    requires = (receipt.get("schema") in _INVARIANT_SCHEMAS
                and _claims_content(receipt))
    declared = receipt.get("expected")
    if declared is None:
        return ["invariant-missing:expected-block-absent"] if requires else []
    if not isinstance(declared, list):
        return ["invariant-unresolvable:expected-not-a-list"]
    # Unknown ruleset -> we cannot honestly re-prove. A current-schema content
    # receipt MUST declare the invariants version we know how to check.
    if requires and receipt.get("expectedVersion") != INVARIANTS_VERSION:
        return [f"invariant-unresolvable:expected-version:{receipt.get('expectedVersion')}"]
    # Content is claimed but there are no invoices to cover it -> `invoices` was
    # stripped while a content surface (totals) was kept. Fail closed.
    if requires and not invoices:
        return ["invariant-missing:invoices-stripped"]

    # Anti-strip: every invoice must be covered by a reconcile invariant and every
    # line by an arithmetic one. A removed declaration is a stripped invariant.
    if requires:
        _check_coverage(declared, invoices, problems)

    for decl in declared:
        if not isinstance(decl, dict):
            problems.append("invariant-unresolvable:malformed-declaration")
            continue
        inv = _resolve_invoice(decl, invoices)
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


def _claims_content(receipt: dict) -> bool:
    """True iff the receipt asserts audited findings — via invoices, a review
    queue, or ANY non-zero total (count OR money: linesChecked, flagged,
    potentialOverchargeUSD, marketOverchargeUSD, policyOverageUSD, …). Any
    positive number in `totals` counts, so no money/finding surface can be kept
    while `invoices` is stripped to dodge the invariant requirement."""
    if receipt.get("invoices") or receipt.get("reviewQueue"):
        return True
    totals = receipt.get("totals")
    if isinstance(totals, dict):
        for v in totals.values():
            if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0:
                return True
    return False


def _resolve_invoice(decl: dict, invoices: list):
    """Resolve a declaration to its invoice by POSITIONAL index — the invoice's
    stable identity. A missing/out-of-range/bool index resolves to None (the
    caller names it unresolvable), so nothing is ever guessed by filename."""
    scope = decl.get("scope")
    if not isinstance(scope, dict):
        return None
    idx = scope.get("invoiceIndex")
    if not isinstance(idx, int) or isinstance(idx, bool) or not (0 <= idx < len(invoices)):
        return None
    inv = invoices[idx]
    return inv if isinstance(inv, dict) else None


def _check_coverage(declared: list, invoices: list, problems: list) -> None:
    """Every invoice needs a reconcile invariant; every line an arithmetic one;
    every line under a taught max a floor invariant. A missing one means the
    block was stripped after audit — fail closed, named per surface (by index)."""
    reconcile = set()
    arithmetic = set()
    floor_max = set()
    for d in declared:
        if not isinstance(d, dict):
            continue
        scope = d.get("scope") if isinstance(d.get("scope"), dict) else {}
        idx = scope.get("invoiceIndex")
        line_key = scope.get("line")
        if not isinstance(idx, int) or isinstance(idx, bool):
            continue  # hostile/absent index — the per-decl loop names it
        kind = d.get("kind")
        if kind == "invoice-reconcile":
            reconcile.add(idx)
            continue
        # line-scoped: a hostile/unhashable `line` must not raise on set-add.
        # Skip it here (leaving the real line uncovered -> named missing) while
        # the per-declaration loop names the bad declaration unresolvable.
        if not isinstance(line_key, int) or isinstance(line_key, bool):
            continue
        if kind == "line-arithmetic":
            arithmetic.add((idx, line_key))
        elif kind == "floor-max-unit-price":
            floor_max.add((idx, line_key))
    for idx, inv in enumerate(invoices):
        if not isinstance(inv, dict):
            continue
        if idx not in reconcile:
            problems.append(f"invariant-missing:invoice-reconcile:{idx}")
        lines = inv.get("lines")
        for i, line in enumerate(lines if isinstance(lines, list) else []):
            if (idx, i) not in arithmetic:
                problems.append(f"invariant-missing:line-arithmetic:{idx}:{i}")
            # A line the floor covers with a max MUST carry its floor invariant —
            # else a stripped floor declaration would bypass verification.
            if _applied_floor_max(line) is not None and (idx, i) not in floor_max:
                problems.append(f"invariant-missing:floor-max-unit-price:{idx}:{i}")


def _check_line_arithmetic(decl: dict, inv: dict, problems: list) -> None:
    line = _line_at(inv, decl)
    if line is None:
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    idx = decl["scope"]["line"]
    operands = decl.get("operands")
    if not isinstance(operands, dict):
        # Legit declarations always pin operands — absent means tampered.
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    try:
        # The pinned operands must match the line — catches a single-field tamper
        # even on an already-flagged line (boolean verdict alone wouldn't move).
        for key in ("qty", "unit_price", "line_total"):
            if abs(_f(line[key]) - _f(operands[key])) > CENT:
                problems.append(f"invariant-violated:{decl.get('id')}")
                return
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
    # The cap comes from the LINE's own recorded floor output (single source of
    # truth), not the declaration's `bound` — a forged high bound in the signed
    # declaration must not be trusted over what the floor recorded. The declared
    # bound is then cross-checked to match; divergence is a tampered declaration.
    # (Residual, documented: both are in the signed body — full re-derivation from
    # the hashed floorRules file is the TMS step, build order #3.)
    applied = _applied_floor_max(line)
    if applied is None:
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    cap = applied[0]
    # A legit floor declaration ALWAYS carries `bound` (build_invariants emits it).
    # Absent bound == tampered: fail closed, never silently skip the cross-check
    # (that skip was a bypass — a forged high appliedMaxUnitPrice with no bound).
    decl_bound = decl.get("bound")
    if decl_bound is None:
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    try:
        if abs(_f(decl_bound) - cap) > CENT:
            problems.append(f"invariant-violated:{decl.get('id')}")
            return
        exceeds = _f(line["unit_price"]) > cap   # strict, matches floor._violation
    except (KeyError, TypeError, ValueError):
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    # Match ONLY a max_unit_price veto — a floor-veto for a different relation
    # (qty_integer, min_unit_price, …) on this line must not be read as the max
    # veto, or it would falsely (mis)match the exceeds-max computation.
    vetoed = _has_flag(inv, "floor-veto", idx, relation_type="max_unit_price")
    if exceeds != vetoed:
        problems.append(f"invariant-violated:{decl.get('id')}")


def _check_invoice_reconcile(decl: dict, inv: dict, problems: list) -> None:
    recorded = inv.get("statedTotalReconciles")
    if not isinstance(recorded, bool):
        # A missing/malformed recorded verdict cannot be re-proven — fail closed
        # rather than let bool(None)==False silently pass a false recomputation.
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    if "statedTotal" not in decl:
        # Legit declarations pin stated_total (possibly null) — absent == tampered.
        problems.append(f"invariant-unresolvable:{decl.get('id')}")
        return
    stated = inv.get("stated_total")
    pinned = decl["statedTotal"]
    try:
        # The pinned stated_total must match the line — catches a tamper on a
        # non-reconciling invoice whose boolean verdict wouldn't otherwise move.
        if (stated is None) != (pinned is None):
            problems.append(f"invariant-violated:{decl.get('id')}")
            return
        if stated is not None and abs(_f(stated) - _f(pinned)) > CENT:
            problems.append(f"invariant-violated:{decl.get('id')}")
            return
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
    """Coerce a recorded number, rejecting bool (True/False are not money). An
    over-large int (e.g. 10**1000000) overflows float — normalize that to
    ValueError so every caller's existing handler fails it closed, never crashes."""
    if isinstance(x, bool):
        raise ValueError("bool is not a number")
    try:
        return float(x)
    except OverflowError as e:
        raise ValueError("number too large to coerce") from e


def _line_at(inv: dict, decl: dict):
    idx = (decl.get("scope") or {}).get("line")
    lines = inv.get("lines")
    if not isinstance(idx, int) or isinstance(idx, bool) or not isinstance(lines, list):
        return None
    if not (0 <= idx < len(lines)):
        return None
    line = lines[idx]
    return line if isinstance(line, dict) else None


def _has_flag(inv: dict, kind: str, line_idx: int, relation_type: str | None = None) -> bool:
    flags = inv.get("flags")
    for f in flags if isinstance(flags, list) else []:
        if not isinstance(f, dict) or f.get("kind") != kind:
            continue
        fl = f.get("line")
        # `False == 0` in Python — a bool line index must not match line 0.
        if isinstance(fl, bool) or fl != line_idx:
            continue
        if relation_type is not None and not _relation_matches(f, relation_type):
            continue
        return True
    return False


def _relation_matches(flag: dict, relation_type: str) -> bool:
    """Match a flag's relation. Prefers the structured `relation_type` field;
    falls back to the detail string for receipts signed before that field
    existed (backward-compat for early v3/invariants-v1 receipts)."""
    rt = flag.get("relation_type")
    if rt is not None:
        return rt == relation_type
    return relation_type in str(flag.get("detail", ""))


def _applied_floor_max(line: dict):
    """Return (max_value, source) for the taught max that covers this line — from
    the floor's `appliedMaxUnitPrice`, which is recorded on passing lines too
    (floor.check_line), so coverage is complete. None when no max rule applied."""
    floor = line.get("floor") if isinstance(line, dict) else None
    field = (floor or {}).get("appliedMaxUnitPrice") if isinstance(floor, dict) else None
    if isinstance(field, dict):
        try:
            return (float(field["object"]), field.get("source"))
        except (KeyError, TypeError, ValueError, OverflowError):
            return None
    return None
