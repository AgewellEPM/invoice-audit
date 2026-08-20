"""Date ordering and data-rot diagnostics for messy historical invoice data."""
from __future__ import annotations

import datetime as _dt
import re
from collections import Counter
from typing import Iterable


DATE_FORMATS = (
    "%Y-%m-%d",
    "%m/%d/%Y",
    "%m/%d/%y",
    "%m-%d-%Y",
    "%m-%d-%y",
    "%Y/%m/%d",
)


def normalize_invoice_date(value: str | None) -> str | None:
    text = (value or "").strip()
    if not text or text.upper() == "UNKNOWN":
        return None
    # OCR sometimes leaves punctuation attached.
    text = re.sub(r"^[^\d]+|[^\d]+$", "", text)
    for fmt in DATE_FORMATS:
        try:
            return _dt.datetime.strptime(text, fmt).date().isoformat()
        except ValueError:
            continue
    return None


def invoice_sort_key(invoice: dict) -> tuple[str, str, str]:
    iso = normalize_invoice_date(str(invoice.get("date", "")))
    return (
        iso or "9999-99-99",
        str(invoice.get("vendor", "")),
        str(invoice.get("invoice_no", "")),
    )


def sort_invoices_chronologically(invoices: Iterable[dict]) -> list[dict]:
    return sorted(invoices, key=invoice_sort_key)


def data_quality_report(
    invoices: Iterable[dict],
    *,
    today: _dt.date | None = None,
) -> dict:
    today = today or _dt.date.today()
    invoice_list = list(invoices)
    issues: list[dict] = []
    timeline: list[dict] = []

    keys = [
        (str(inv.get("vendor", "")).strip().upper(),
         str(inv.get("invoice_no", "")).strip().upper())
        for inv in invoice_list
    ]
    duplicates = {key for key, count in Counter(keys).items()
                  if key[0] and key[1] and key[1] != "UNKNOWN" and count > 1}

    for inv in sort_invoices_chronologically(invoice_list):
        raw_date = str(inv.get("raw_date") or inv.get("date") or "")
        iso = normalize_invoice_date(str(inv.get("date", "")))
        timeline.append({
            "invoice": inv.get("file", ""),
            "vendor": inv.get("vendor", ""),
            "invoice_no": inv.get("invoice_no", ""),
            "date": iso,
            "raw_date": raw_date,
        })
        if iso is None:
            issues.append({
                "kind": "missing-or-unreadable-date",
                "severity": "evidence",
                "invoice": inv.get("file", ""),
                "detail": f"invoice date could not be normalized: {raw_date or 'missing'}",
            })
        else:
            parsed = _dt.date.fromisoformat(iso)
            if parsed > today + _dt.timedelta(days=1):
                issues.append({
                    "kind": "future-dated-invoice",
                    "severity": "evidence",
                    "invoice": inv.get("file", ""),
                    "detail": f"invoice date {iso} is in the future",
                })

        key = (
            str(inv.get("vendor", "")).strip().upper(),
            str(inv.get("invoice_no", "")).strip().upper(),
        )
        if key in duplicates:
            issues.append({
                "kind": "duplicate-invoice-number",
                "severity": "evidence",
                "invoice": inv.get("file", ""),
                "detail": f"duplicate invoice number {inv.get('invoice_no')} for {inv.get('vendor')}",
            })

    return {
        "orderedBy": "invoice_date,vendor,invoice_no",
        "timeline": timeline,
        "issues": issues,
        "issueCount": len(issues),
    }
