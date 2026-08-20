"""Arithmetic gate — the deterministic layer that never guesses.

Every extracted line must satisfy qty x unit == total (to the cent), and the
lines must sum to the invoice's own stated total when one is printed. A
mismatch is NOT an audit verdict about pricing — it means either the invoice
is internally wrong or the extraction misread; both go to a human. This is
what keeps a probabilistic OCR/extraction front-end honest.
"""
from __future__ import annotations

from .layout import ParsedInvoice

CENT = 0.005  # half-cent tolerance for float representation

# OCR confidence below this sends the line to review rather than trusting it.
MIN_CONFIDENCE = 0.6


def arithmetic_flags(inv: ParsedInvoice) -> list[dict]:
    flags: list[dict] = []
    for i, line in enumerate(inv.lines):
        expected = round(line.qty * line.unit_price, 2)
        if abs(expected - line.line_total) > CENT:
            flags.append({
                "kind": "arithmetic-mismatch",
                "line": i,
                "detail": f"qty {line.qty} x unit {line.unit_price:.2f} = "
                          f"{expected:.2f}, invoice says {line.line_total:.2f}",
            })
        if line.min_confidence < MIN_CONFIDENCE:
            flags.append({
                "kind": "low-confidence",
                "line": i,
                "detail": f"OCR confidence {line.min_confidence:.2f} below "
                          f"{MIN_CONFIDENCE} — human must read this line",
            })
    if inv.stated_total is not None:
        lines_sum = round(sum(l.line_total for l in inv.lines), 2)
        if abs(lines_sum - inv.stated_total) > CENT:
            flags.append({
                "kind": "total-mismatch",
                "line": None,
                "detail": f"line items sum to {lines_sum:.2f}, invoice states "
                          f"{inv.stated_total:.2f} — items misread or missing",
            })
    return flags
