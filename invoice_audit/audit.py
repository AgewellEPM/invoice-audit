"""Orchestration — scan folder in, signed receipt out.

The human gate is structural: NOTHING is auto-approved or auto-rejected.
Clean lines are reported clean; every flag (overcharge, no-reference,
arithmetic-mismatch, low-confidence) lands in the review queue for a person.
The receipt records exactly what was checked, against what, with what
verdicts — and is signed.
"""
from __future__ import annotations

import datetime
from pathlib import Path

from .layout import parse_invoice
from .ocr import AuditError, ocr_image, sha256_file
from .pricebook import PriceBook
from .receipt import SCHEMA, sign_receipt
from .validate import arithmetic_flags

SCAN_EXTS = {".png", ".jpg", ".jpeg", ".tiff", ".pdf"}


def audit_folder(scans_dir: Path, pricebook_path: Path,
                 tolerance: float = 0.15) -> dict:
    if not scans_dir.is_dir():
        raise AuditError(f"scans-dir-missing:{scans_dir}")
    scans = sorted(p for p in scans_dir.iterdir()
                   if p.suffix.lower() in SCAN_EXTS)
    if not scans:
        raise AuditError(f"no-scans-found:{scans_dir}")
    for p in scans:
        if p.suffix.lower() == ".pdf":
            raise AuditError("pdf-not-wired:render PDFs to PNG first "
                             "(roadmap — labelled, not silently skipped)")

    book = PriceBook.load(pricebook_path)

    invoices = []
    review_queue = []
    potential_overcharge = 0.0
    for scan in scans:
        tokens = ocr_image(scan)
        parsed = parse_invoice(tokens)
        flags = arithmetic_flags(parsed)
        lines = []
        for i, line in enumerate(parsed.lines):
            check = book.check(line, tolerance=tolerance)
            lines.append({
                "sku": line.sku, "description": line.description,
                "qty": line.qty, "unit_price": line.unit_price,
                "line_total": line.line_total,
                "ocr_min_confidence": round(line.min_confidence, 3),
                **check,
            })
            if check["verdict"] != "ok":
                flags.append({"kind": check["verdict"], "line": i,
                              "detail": check["detail"]})
            potential_overcharge += check.get("delta_total", 0.0)
        invoice = {
            "file": scan.name, "path": str(scan), "sha256": sha256_file(scan),
            "vendor": parsed.vendor, "invoice_no": parsed.invoice_no,
            "date": parsed.date, "stated_total": parsed.stated_total,
            "lines": lines, "flags": flags,
            "disposition": "flagged" if flags else "clean",
        }
        invoices.append(invoice)
        for f in flags:
            review_queue.append({"invoice": scan.name, **f})

    body = {
        "schema": SCHEMA,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "engine": {"ocr": "apple-vision/vision-ocr",
                   "extraction": "deterministic-layout-v1"},
        "scans": [{"path": inv["path"], "file": inv["file"],
                   "sha256": inv["sha256"]} for inv in invoices],
        "pricebook": {"path": str(pricebook_path),
                      "sha256": book.source_sha256,
                      "rows": len(book.rows)},
        "toleranceRatio": tolerance,
        "invoices": invoices,
        "reviewQueue": review_queue,
        "totals": {
            "invoices": len(invoices),
            "linesChecked": sum(len(i["lines"]) for i in invoices),
            "flagged": len(review_queue),
            "potentialOverchargeUSD": round(potential_overcharge, 2),
        },
        "humanGate": "nothing auto-approved; every flag requires a person",
    }
    return sign_receipt(body)
