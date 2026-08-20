"""Per-site pins for the invoice-audit engine. Run: python3 -m pytest tests/ -q
(or python3 tests/test_invoice_audit.py to run without pytest).

Each stage is pinned independently; the end-to-end test asserts the three
planted cases (overcharge / arithmetic / no-reference) each flag, by name.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from invoice_audit.audit import audit_folder  # noqa: E402
from invoice_audit.layout import parse_invoice  # noqa: E402
from invoice_audit.ocr import AuditError, Token  # noqa: E402
from invoice_audit.pricebook import PriceBook, ReferenceRow  # noqa: E402
from invoice_audit.receipt import sign_receipt, verify_receipt, SCHEMA  # noqa: E402
from invoice_audit.validate import arithmetic_flags  # noqa: E402

DEMO = ROOT / "demo"


def _ensure_fixtures() -> None:
    if not (DEMO / "scans" / "invoice-30071.png").exists():
        subprocess.run([sys.executable, str(DEMO / "make_fixtures.py")], check=True)
    if not (ROOT / "bin" / "vision-ocr").exists():
        subprocess.run([str(ROOT / "scripts" / "build.sh")], check=True)


# --- layout: deterministic extraction, fail-closed on no headers ---

def _tok(text, x, y, w=0.1, h=0.03, conf=0.99):
    return Token(text=text, confidence=conf, x=x, y=y, w=w, h=h)


def test_layout_extracts_line_and_sku():
    toks = [
        _tok("ACME", 0.05, 0.05),
        _tok("QTY", 0.05, 0.20), _tok("DESCRIPTION", 0.20, 0.20),
        _tok("UNIT", 0.65, 0.20), _tok("TOTAL", 0.85, 0.20),
        _tok("2", 0.05, 0.30), _tok("HYD-4410", 0.20, 0.30),
        _tok("PUMP", 0.32, 0.30), _tok("$2,950.00", 0.65, 0.30),
        _tok("$5,900.00", 0.85, 0.30),
    ]
    inv = parse_invoice(toks)
    assert len(inv.lines) == 1, "one line item extracted"
    assert inv.lines[0].sku == "HYD-4410", "SKU split from description"
    assert inv.lines[0].qty == 2 and inv.lines[0].unit_price == 2950.00


def test_layout_fails_closed_without_headers():
    toks = [_tok("just", 0.1, 0.1), _tok("text", 0.2, 0.1)]
    try:
        parse_invoice(toks)
        assert False, "must raise"
    except AuditError as e:
        assert "layout-no-table-headers" in str(e)


# --- arithmetic gate ---

def test_arithmetic_flags_qty_times_unit_mismatch():
    from invoice_audit.layout import LineItem, ParsedInvoice
    inv = ParsedInvoice("V", "1", "d", lines=[
        LineItem("A", "x", qty=2, unit_price=412.50, line_total=1279.00,
                 min_confidence=0.99)])
    flags = arithmetic_flags(inv)
    assert any(f["kind"] == "arithmetic-mismatch" for f in flags)


def test_low_confidence_line_flagged_for_human():
    from invoice_audit.layout import LineItem, ParsedInvoice
    inv = ParsedInvoice("V", "1", "d", lines=[
        LineItem("A", "x", qty=1, unit_price=10.0, line_total=10.0,
                 min_confidence=0.4)])
    assert any(f["kind"] == "low-confidence" for f in arithmetic_flags(inv))


# --- pricebook: the three verdicts, each pinned ---

def _book():
    return PriceBook([
        ReferenceRow("HYD-4410", "HYDRAULIC PUMP ASSY", 2950.0),
        ReferenceRow("HYD-4410", "HYDRAULIC PUMP ASSY", 3010.0),
        ReferenceRow("FLT-2200", "FORKLIFT BRAKE KIT", 400.0),
    ], DEMO / "pricebook.csv")


def test_pricebook_flags_overcharge():
    from invoice_audit.layout import LineItem
    line = LineItem("HYD-4410", "HYDRAULIC PUMP ASSY", 1, 5980.0, 5980.0, 0.99)
    v = _book().check(line)
    assert v["verdict"] == "overcharge-flag"
    assert v["reference_median"] == 2980.0  # median(2950,3010)


def test_pricebook_passes_in_range_price():
    from invoice_audit.layout import LineItem
    line = LineItem("FLT-2200", "FORKLIFT BRAKE KIT", 1, 415.0, 415.0, 0.99)
    assert _book().check(line)["verdict"] == "ok"


def test_pricebook_no_reference_never_silently_passes():
    from invoice_audit.layout import LineItem
    line = LineItem("SEN-7781", "PROXIMITY SENSOR", 1, 88.0, 88.0, 0.99)
    assert _book().check(line)["verdict"] == "no-reference"


# --- receipt: sign, verify, tamper-detect ---

def test_receipt_signs_and_verifies():
    body = {"schema": SCHEMA, "scans": [], "pricebook": {}, "x": 1}
    r = sign_receipt(body)
    assert verify_receipt(r, rehash_inputs=False) == []


def test_receipt_detects_tampered_body():
    body = {"schema": SCHEMA, "scans": [], "pricebook": {}, "x": 1}
    r = sign_receipt(body)
    r["x"] = 2  # tamper
    assert "receipt-signature-invalid" in verify_receipt(r, rehash_inputs=False)


# --- end-to-end: the three planted cases each flag, by name ---

def test_end_to_end_three_planted_cases_flag():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv")
    kinds = {(item["invoice"], item["kind"]) for item in receipt["reviewQueue"]}
    assert ("invoice-30071.png", "overcharge-flag") in kinds, "forklift overcharge"
    assert ("invoice-30073.png", "arithmetic-mismatch") in kinds, "math error"
    assert ("invoice-30073.png", "no-reference") in kinds, "no history"
    assert receipt["totals"]["potentialOverchargeUSD"] > 5000, "catches ~$6k"
    assert verify_receipt(receipt, rehash_inputs=True) == [], "receipt verifies"
    # clean invoice produces NO flags
    assert not any(i["invoice"] == "invoice-30072.png" for i in receipt["reviewQueue"])


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
        passed += 1
    print(f"\n{passed}/{len(fns)} passed")
