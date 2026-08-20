"""Grounding layer — the anti-hallucination guarantee for the number pipeline.

The arithmetic gate (validate.py) catches an *inconsistent* line: change one
digit and qty*unit != total. What it CANNOT catch is a line where OCR misread
every value into a *self-consistent* wrong triple — read `1 x 5980 = 5980` when
the paper said `1 x 5960 = 5960`. That line passes arithmetic, and if the SKU
has no price history it ships wrong and signed. Across 1,000 files, some of
those slip through. That is the hallucination Luke named.

Grounding refuses to *emit as trusted* any money number it cannot trace to a
single clean, high-confidence OCR token AND corroborate with an independent
witness. The verdict ladder borrows the Peel `resolve` vocabulary:

  grounded     — every number traces to a clean token >= GROUND_CONFIDENCE and
                 the line carries an independent witness (price history, or the
                 invoice's printed grand total reconciles). Trust it.
  needs-review — readable but weak: untethered (qty*unit != total), or no
                 independent witness (self-consistent only), or confidence in
                 the grey band. A human decides; it is NOT auto-trusted.
  ungrounded   — a number could not be read to a clean token, or is below the
                 illegibility floor. FAIL CLOSED — never emitted as a value.

Every verdict carries the trace (token text, confidence, pixel bbox, witnesses)
into the signed receipt, so "grounded" means *traceable to evidence*, not "the
model was confident".

HONEST LIMIT (documented, not hidden): this closes ungrounded and untethered
numbers. It does NOT by itself defeat a *high-confidence, self-consistent*
misread that also happens to carry a witness — closing that residual requires a
second independent read (digit-for-digit agreement), which is the next brick,
not this one. See README "number pipeline".
"""
from __future__ import annotations

from .layout import LineItem, ParsedInvoice

# A number read below this confidence is illegible — fail closed, never emit.
HARD_FLOOR = 0.50
# At/above this a number is trusted enough to be "grounded" (vs needs-review).
GROUND_CONFIDENCE = 0.80
CENT = 0.005


def _num_trace(tok) -> dict | None:
    """Provenance for one number: its text, confidence, and pixel box."""
    if tok is None:
        return None
    return {
        "text": tok.text,
        "confidence": round(tok.confidence, 3),
        "bbox": [round(tok.x, 4), round(tok.y, 4),
                 round(tok.w, 4), round(tok.h, 4)],
    }


def arithmetic_ok(line: LineItem) -> bool:
    return abs(round(line.qty * line.unit_price, 2) - line.line_total) <= CENT


def stated_total_reconciles(inv: ParsedInvoice) -> bool:
    """The invoice's own printed grand total is an independent witness for the
    set of line totals. None printed → no witness (returns False)."""
    if inv.stated_total is None:
        return False
    lines_sum = round(sum(l.line_total for l in inv.lines), 2)
    return abs(lines_sum - inv.stated_total) <= CENT


def ground_line(line: LineItem, *, invoice_reconciles: bool,
                price_matched: bool) -> dict:
    """Grounding verdict + full trace for one line's three money numbers."""
    numbers = {
        "qty": _num_trace(line.qty_tok),
        "unit": _num_trace(line.unit_tok),
        "total": _num_trace(line.total_tok),
    }
    missing = [k for k, v in numbers.items() if v is None]
    confs = [v["confidence"] for v in numbers.values() if v is not None]
    arith = arithmetic_ok(line)

    witnesses: list[str] = []
    if price_matched:
        witnesses.append("price-history")
    if invoice_reconciles:
        witnesses.append("stated-total-reconciles")
    if arith:
        witnesses.append("arithmetic-consistent")

    if missing:
        verdict, reason = "ungrounded", f"no-source-token:{','.join(missing)}"
    elif confs and min(confs) < HARD_FLOOR:
        verdict, reason = "ungrounded", f"illegible:min-confidence-{min(confs):.2f}"
    elif not arith:
        verdict, reason = ("needs-review",
                           "untethered:qty*unit!=total — number not cross-checked")
    elif not (price_matched or invoice_reconciles):
        verdict, reason = ("needs-review",
                           "no-independent-witness:self-consistent only")
    elif confs and min(confs) < GROUND_CONFIDENCE:
        verdict, reason = ("needs-review",
                           f"low-grounding-confidence-{min(confs):.2f}")
    else:
        verdict, reason = ("grounded",
                           "traced to clean tokens + independent witness")

    return {
        "verdict": verdict,
        "reason": reason,
        "numbers": numbers,
        "witnesses": witnesses,
    }
