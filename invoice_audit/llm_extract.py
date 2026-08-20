"""Optional LLM extraction/review seam.

The safe default is deterministic extraction. If an LLM result is supplied
through a fixture or future provider, this module compares it to the extracted
line items and emits human-review disagreements. It never auto-approves money.
"""
from __future__ import annotations

import json
import os
from pathlib import Path


LINE_SCHEMA = {
    "type": "object",
    "required": ["vendor", "invoice_no", "date", "lines"],
    "properties": {
        "vendor": {"type": "string"},
        "invoice_no": {"type": "string"},
        "date": {"type": "string"},
        "lines": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["sku", "description", "qty", "unit_price", "line_total"],
                "properties": {
                    "sku": {"type": "string"},
                    "description": {"type": "string"},
                    "qty": {"type": "number"},
                    "unit_price": {"type": "number"},
                    "line_total": {"type": "number"},
                },
            },
        },
    },
}


def review_if_configured(parsed_invoice, file_name: str) -> dict:
    fixture = os.environ.get("INVOICE_AUDIT_LLM_FIXTURE")
    if not fixture:
        return {
            "enabled": False,
            "provider": "not-configured",
            "schema": LINE_SCHEMA,
            "disagreements": [],
        }

    data = json.loads(Path(fixture).read_text())
    doc = data.get(file_name) if isinstance(data, dict) else None
    if doc is None:
        return {
            "enabled": True,
            "provider": "fixture",
            "schema": LINE_SCHEMA,
            "disagreements": [{
                "kind": "llm-missing-document",
                "detail": f"LLM fixture has no extraction for {file_name}",
            }],
        }

    disagreements = _compare(parsed_invoice, doc)
    return {
        "enabled": True,
        "provider": "fixture",
        "schema": LINE_SCHEMA,
        "disagreements": disagreements,
    }


def _compare(parsed_invoice, doc: dict) -> list[dict]:
    disagreements: list[dict] = []
    if str(doc.get("invoice_no", "")) and str(doc.get("invoice_no", "")) != parsed_invoice.invoice_no:
        disagreements.append({
            "kind": "llm-invoice-number-disagreement",
            "detail": f"layout={parsed_invoice.invoice_no} llm={doc.get('invoice_no')}",
        })
    llm_lines = doc.get("lines", []) or []
    if len(llm_lines) != len(parsed_invoice.lines):
        disagreements.append({
            "kind": "llm-line-count-disagreement",
            "detail": f"layout={len(parsed_invoice.lines)} llm={len(llm_lines)}",
        })
    for idx, line in enumerate(parsed_invoice.lines):
        if idx >= len(llm_lines):
            break
        llm = llm_lines[idx]
        for field, layout_value, tolerance in (
            ("sku", line.sku, None),
            ("qty", line.qty, 0.0001),
            ("unit_price", line.unit_price, 0.01),
            ("line_total", line.line_total, 0.01),
        ):
            llm_value = llm.get(field)
            if tolerance is None:
                differs = str(layout_value) != str(llm_value)
            else:
                try:
                    differs = abs(float(layout_value) - float(llm_value)) > tolerance
                except (TypeError, ValueError):
                    differs = True
            if differs:
                disagreements.append({
                    "kind": "llm-line-field-disagreement",
                    "line": idx,
                    "detail": f"{field}: layout={layout_value} llm={llm_value}",
                })
    return disagreements
