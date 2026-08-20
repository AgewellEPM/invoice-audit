"""Layout stage — deterministic line-item reconstruction from OCR tokens.

No model guesses here: rows are grouped by y-band, columns are anchored to
the table's own header tokens (QTY / DESCRIPTION / UNIT / TOTAL variants).
An invoice whose table headers can't be found fails CLOSED with a named
reason — extraction never silently degrades into "best effort".
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from .ocr import AuditError, Token

HEADER_SYNONYMS = {
    "qty": {"qty", "quantity", "qnty"},
    "desc": {"description", "item", "desc", "part"},
    "unit": {"unit", "price", "unitprice", "each", "rate"},
    "total": {"total", "amount", "ext", "extended"},
}

MONEY = re.compile(r"^\$?-?[\d,]+\.\d{2}$")
QTY = re.compile(r"^\d{1,5}$")

# Header fields (vendor/invoice no/date) read from the top region.
INVOICE_NO = re.compile(r"(?:invoice|inv)[^\d]{0,10}(\d{3,12})", re.I)
DATE = re.compile(r"\b(\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2})\b")


@dataclass
class LineItem:
    sku: str
    description: str
    qty: float
    unit_price: float
    line_total: float
    min_confidence: float
    row_text: str = ""


@dataclass
class ParsedInvoice:
    vendor: str
    invoice_no: str
    date: str
    lines: list[LineItem] = field(default_factory=list)
    stated_total: float | None = None


def _rows(tokens: list[Token], tol: float = 0.012) -> list[list[Token]]:
    """Group tokens into visual rows by y-center proximity."""
    rows: list[list[Token]] = []
    for t in sorted(tokens, key=lambda t: t.cy):
        if rows and abs(rows[-1][0].cy - t.cy) <= tol:
            rows[-1].append(t)
        else:
            rows.append([t])
    for r in rows:
        r.sort(key=lambda t: t.x)
    return rows


def _money(s: str) -> float:
    return float(s.replace("$", "").replace(",", ""))


def _find_header_row(rows: list[list[Token]]) -> tuple[int, dict[str, float]]:
    """Locate the table header row; return (row index, column anchor x by field)."""
    for i, row in enumerate(rows):
        anchors: dict[str, float] = {}
        for tok in row:
            word = re.sub(r"[^a-z]", "", tok.text.lower())
            for feld, names in HEADER_SYNONYMS.items():
                if word in names and feld not in anchors:
                    anchors[feld] = tok.cx
        if {"qty", "desc", "unit", "total"} <= set(anchors):
            return i, anchors
    raise AuditError("layout-no-table-headers")


def _nearest(anchors: dict[str, float], x: float) -> str:
    return min(anchors, key=lambda k: abs(anchors[k] - x))


def parse_invoice(tokens: list[Token]) -> ParsedInvoice:
    if not tokens:
        raise AuditError("layout-empty-page")
    rows = _rows(tokens)
    header_i, anchors = _find_header_row(rows)

    # Top region → vendor (first prominent line) + invoice no + date.
    top_text = " ".join(t.text for r in rows[:header_i] for t in r)
    vendor = " ".join(t.text for t in rows[0]) if rows else "UNKNOWN"
    m_no = INVOICE_NO.search(top_text)
    m_date = DATE.search(top_text)

    parsed = ParsedInvoice(
        vendor=vendor.strip(),
        invoice_no=m_no.group(1) if m_no else "UNKNOWN",
        date=m_date.group(1) if m_date else "UNKNOWN",
    )

    for row in rows[header_i + 1 :]:
        cells: dict[str, list[Token]] = {}
        for tok in row:
            cells.setdefault(_nearest(anchors, tok.cx), []).append(tok)
        row_text = " ".join(t.text for t in row)

        # A stated grand-total row ends the table.
        if re.search(r"\b(grand\s*)?total\b", row_text, re.I) and "desc" not in cells:
            monies = [t.text for t in row if MONEY.match(t.text)]
            if monies:
                parsed.stated_total = _money(monies[-1])
            break

        qty_toks = [t for t in cells.get("qty", []) if QTY.match(t.text)]
        unit_toks = [t for t in cells.get("unit", []) if MONEY.match(t.text)]
        total_toks = [t for t in cells.get("total", []) if MONEY.match(t.text)]
        desc_toks = cells.get("desc", [])
        if not (qty_toks and unit_toks and total_toks and desc_toks):
            continue  # separator/notes row — not a line item

        desc_text = " ".join(t.text for t in desc_toks)
        # Leading token that looks like a part number becomes the SKU.
        sku_m = re.match(r"^([A-Z]{2,}-?\d{2,})\b\s*(.*)$", desc_text)
        sku, desc = (sku_m.group(1), sku_m.group(2)) if sku_m else ("", desc_text)

        used = qty_toks[:1] + unit_toks[:1] + total_toks[:1] + desc_toks
        parsed.lines.append(
            LineItem(
                sku=sku,
                description=desc.strip(),
                qty=float(qty_toks[0].text),
                unit_price=_money(unit_toks[0].text),
                line_total=_money(total_toks[0].text),
                min_confidence=min(t.confidence for t in used),
                row_text=row_text,
            )
        )

    if not parsed.lines:
        raise AuditError("layout-no-line-items")
    return parsed
