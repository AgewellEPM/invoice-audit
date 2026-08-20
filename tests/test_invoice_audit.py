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
from invoice_audit.floor import Floor, Rule  # noqa: E402
from invoice_audit.grounding import (  # noqa: E402
    GROUND_CONFIDENCE, ground_line, stated_total_reconciles)
from invoice_audit.layout import LineItem, ParsedInvoice, parse_invoice  # noqa: E402
from invoice_audit.ocr import AuditError, Token  # noqa: E402
from invoice_audit.pricebook import PriceBook, ReferenceRow  # noqa: E402
from invoice_audit.receipt import sign_receipt, verify_receipt, SCHEMA  # noqa: E402
from invoice_audit.validate import arithmetic_flags  # noqa: E402

DEMO = ROOT / "demo"


def _ensure_fixtures() -> None:
    if not (DEMO / "scans" / "invoice-30071.png").exists():
        subprocess.run([sys.executable, str(DEMO / "make_fixtures.py")], check=True)
    # The native vision-ocr helper is macOS-only. Windows and Linux exercise
    # the same pipeline through Tesseract and must never try to execute the
    # repository's shell build script.
    if sys.platform == "darwin" and not (ROOT / "bin" / "vision-ocr").exists():
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
    # The clean invoice produces no financial/policy finding. A backend may
    # still fail closed with low-confidence review (notably Tesseract on Win11).
    clean_flags = [i["kind"] for i in receipt["reviewQueue"]
                   if i["invoice"] == "invoice-30072.png"]
    assert set(clean_flags) <= {"low-confidence"}, clean_flags


# --- grounding: the number pipeline never emits an ungrounded number ---

def _line_tok(qty, unit, total, conf=0.99, sku="X", desc="d"):
    qtxt = str(int(qty)) if qty == int(qty) else str(qty)
    qtok = Token(qtxt, conf, 0.05, 0.30, 0.03, 0.03)
    utok = Token(f"${unit:,.2f}", conf, 0.65, 0.30, 0.10, 0.03)
    ttok = Token(f"${total:,.2f}", conf, 0.85, 0.30, 0.10, 0.03)
    return LineItem(sku, desc, qty, unit, total, conf, "", qtok, utok, ttok)


def test_grounding_grounded_with_price_witness():
    g = ground_line(_line_tok(1, 100.0, 100.0),
                    invoice_reconciles=False, price_matched=True)
    assert g["verdict"] == "grounded", g
    assert "price-history" in g["witnesses"]
    assert g["numbers"]["unit"]["bbox"], "trace carries the pixel box"


def test_grounding_grounded_via_stated_total_only():
    g = ground_line(_line_tok(1, 100.0, 100.0),
                    invoice_reconciles=True, price_matched=False)
    assert g["verdict"] == "grounded"
    assert "stated-total-reconciles" in g["witnesses"]


def test_grounding_needs_review_untethered_number():
    # OCR read a self-consistent-looking line but qty*unit != total.
    g = ground_line(_line_tok(1, 5980.0, 5960.0),
                    invoice_reconciles=True, price_matched=True)
    assert g["verdict"] == "needs-review"
    assert "untethered" in g["reason"]


def test_grounding_needs_review_no_independent_witness():
    # arithmetic ok but nothing external corroborates the unit price.
    g = ground_line(_line_tok(1, 100.0, 100.0),
                    invoice_reconciles=False, price_matched=False)
    assert g["verdict"] == "needs-review"
    assert "no-independent-witness" in g["reason"]


def test_grounding_ungrounded_when_token_missing_fails_closed():
    line = _line_tok(1, 100.0, 100.0)
    line.unit_tok = None  # OCR couldn't isolate the unit-price token
    g = ground_line(line, invoice_reconciles=True, price_matched=True)
    assert g["verdict"] == "ungrounded"
    assert "no-source-token:unit" in g["reason"]


def test_grounding_ungrounded_when_illegible_fails_closed():
    g = ground_line(_line_tok(1, 100.0, 100.0, conf=0.30),
                    invoice_reconciles=True, price_matched=True)
    assert g["verdict"] == "ungrounded"
    assert "illegible" in g["reason"]


def test_grounding_low_confidence_band_is_needs_review():
    conf = (GROUND_CONFIDENCE + 0.50) / 2  # between hard floor and ground floor
    g = ground_line(_line_tok(1, 100.0, 100.0, conf=conf),
                    invoice_reconciles=True, price_matched=True)
    assert g["verdict"] == "needs-review"
    assert "low-grounding-confidence" in g["reason"]


def test_stated_total_reconciles_helper():
    inv = ParsedInvoice("V", "1", "d", lines=[
        LineItem("A", "x", 1, 10.0, 10.0, 0.99),
        LineItem("B", "y", 2, 5.0, 10.0, 0.99)], stated_total=20.0)
    assert stated_total_reconciles(inv) is True
    inv.stated_total = 25.0
    assert stated_total_reconciles(inv) is False
    inv.stated_total = None
    assert stated_total_reconciles(inv) is False


# --- floor: taught symbolic rules, fail-closed, real veto ---

def _sen_floor():
    return Floor([Rule("SEN-7781", "max_unit_price", "60.00",
                       "ops:test", "sensors never above 60")])


def test_floor_vetoes_over_taught_max():
    check = _sen_floor().check_line(
        LineItem("SEN-7781", "PROXIMITY SENSOR HD", 6, 88.0, 528.0, 0.99))
    assert check["verdict"] == "contradiction" and check["veto"] is True
    assert check["conflicts"][0]["relation_type"] == "max_unit_price"
    assert check["conflicts"][0]["source"] == "ops:test", "provenance carried"


def test_floor_consistent_when_within_taught_max():
    check = _sen_floor().check_line(
        LineItem("SEN-7781", "PROXIMITY SENSOR HD", 6, 50.0, 300.0, 0.99))
    assert check["verdict"] == "consistent" and check["veto"] is False


def test_floor_abstains_unknown_when_no_rule_applies():
    check = _sen_floor().check_line(
        LineItem("OTHER-1", "SOMETHING ELSE", 1, 10.0, 10.0, 0.99))
    assert check["verdict"] == "unknown" and check["veto"] is False


def test_floor_qty_integer_veto():
    f = Floor([Rule("*", "qty_integer", "true", "seed", "whole units only")])
    check = f.check_line(LineItem("A", "x", 2.5, 10.0, 25.0, 0.99))
    assert check["veto"] is True


def test_floor_unit_price_positive_veto():
    f = Floor([Rule("*", "unit_price_positive", "0", "seed", "must be > 0")])
    check = f.check_line(LineItem("A", "x", 1, 0.0, 0.0, 0.99))
    assert check["veto"] is True


def test_floor_refuses_unknown_relation():
    try:
        Floor([Rule("A", "bogus_relation", "1", "s", "e")])
        assert False, "must refuse unknown relation"
    except AuditError as e:
        assert "floor-unknown-relation" in str(e)


def test_floor_refuses_missing_provenance():
    try:
        Floor([Rule("A", "max_unit_price", "10", "", "e")])
        assert False, "must refuse missing source"
    except AuditError as e:
        assert "floor-missing-provenance" in str(e)


def test_floor_refuses_conflicting_rule():
    try:
        Floor([Rule("A", "max_unit_price", "10", "s", "e"),
               Rule("A", "max_unit_price", "20", "s2", "e2")])
        assert False, "must refuse conflicting max for same subject"
    except AuditError as e:
        assert "floor-conflict" in str(e)


def test_floor_idempotent_identical_rule():
    f = Floor([Rule("A", "max_unit_price", "10", "s", "e"),
               Rule("A", "max_unit_price", "10", "s", "e")])
    assert len(f.rules) == 1


def test_floor_loads_demo_rules_file():
    f = Floor.load(DEMO / "floor-rules.json")
    assert len(f.rules) == 3


# --- end-to-end WITH the floor: veto + grounding + policy total, by name ---

def test_end_to_end_floor_veto_and_grounding():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    kinds = {(item["invoice"], item["kind"]) for item in receipt["reviewQueue"]}
    # floor catches the no-history sensor the pricebook could only shrug at
    assert ("invoice-30073.png", "floor-veto") in kinds, "taught-rule veto"
    assert ("invoice-30073.png", "no-reference") in kinds, "pricebook blind"
    # grounding independently flags the untethered 1279.00 total
    assert ("invoice-30073.png", "weak-grounding") in kinds, "untethered number"
    assert receipt["totals"]["policyOverageUSD"] > 0, "floor overage counted"
    # the clean pump line is positively grounded (traceable + witnessed)
    inv71 = next(i for i in receipt["invoices"] if i["file"] == "invoice-30071.png")
    assert inv71["lines"][0]["grounding"]["verdict"] == "grounded"
    # No money/policy finding is allowed on the clean invoice; conservative
    # OCR uncertainty review remains valid fail-closed behavior.
    clean_flags = [i["kind"] for i in receipt["reviewQueue"]
                   if i["invoice"] == "invoice-30072.png"]
    assert set(clean_flags) <= {"low-confidence"}, clean_flags
    # taught rules are pinned into the receipt and it verifies
    assert receipt["floorRules"]["rules"] == 3
    assert verify_receipt(receipt, rehash_inputs=True) == []


def test_floor_rules_tamper_is_detected():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    receipt["floorRules"]["sha256"] = "0" * 64  # pretend different rules ran
    problems = verify_receipt(receipt)
    assert any("floor-rules-hash-changed" in p for p in problems), problems


# --- cross-platform: the Windows OCR backend yields the same money verdicts ---

def test_tesseract_backend_matches_core_verdicts():
    """The Windows OCR path (Tesseract) runs the identical pipeline. Same scans,
    different engine → same overcharge / arithmetic / floor-veto verdicts. Skips
    cleanly where Tesseract isn't installed."""
    import os
    import shutil
    if not shutil.which("tesseract"):
        print("    (skipped: tesseract not installed)")
        return
    _ensure_fixtures()
    prev = os.environ.get("INVOICE_AUDIT_OCR")
    os.environ["INVOICE_AUDIT_OCR"] = "tesseract"
    try:
        receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                               floor_path=DEMO / "floor-rules.json")
    finally:
        if prev is None:
            os.environ.pop("INVOICE_AUDIT_OCR", None)
        else:
            os.environ["INVOICE_AUDIT_OCR"] = prev
    kinds = {(i["invoice"], i["kind"]) for i in receipt["reviewQueue"]}
    assert ("invoice-30071.png", "overcharge-flag") in kinds, "pump overcharge"
    assert ("invoice-30073.png", "arithmetic-mismatch") in kinds, "math error"
    assert ("invoice-30073.png", "floor-veto") in kinds, "taught-rule veto"
    assert receipt["totals"]["potentialOverchargeUSD"] > 5000
    assert receipt["totals"]["policyOverageUSD"] > 0
    assert verify_receipt(receipt, rehash_inputs=True) == [], "receipt verifies"


# --- pure Ed25519 fallback: byte-identical + interoperable with cryptography ---

def test_pure_ed25519_matches_cryptography_byte_for_byte():
    from invoice_audit import _ed25519_pure as ed
    import invoice_audit.receipt as receipt_backend
    if not receipt_backend.HAVE_CRYPTOGRAPHY:
        # RFC 8032 section 7.1, test vector 1. Windows ARM64 may have no
        # cryptography wheel; the standard vector remains an independent,
        # byte-exact interoperability pin without retrying a broken import.
        seed = bytes.fromhex(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        pub = bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        sig = bytes.fromhex(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
            "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        assert ed.publickey(seed) == pub
        assert ed.signature(b"", seed, pub) == sig
        assert ed.checkvalid(sig, b"", pub) is True
        return
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey, Ed25519PublicKey)
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    seed = bytes(range(32))
    msg = b"invoice-audit receipt canonical bytes"
    k = Ed25519PrivateKey.from_private_bytes(seed)
    cpub = k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    csig = k.sign(msg)
    # Ed25519 is deterministic (RFC 8032) → identical bytes, not just valid.
    assert ed.publickey(seed) == cpub, "pubkey differs from cryptography"
    assert ed.signature(msg, seed, cpub) == csig, "signature differs"
    # cross-verify both directions (guest-signed verifies on host and vice-versa)
    assert ed.checkvalid(csig, msg, cpub) is True
    Ed25519PublicKey.from_public_bytes(ed.publickey(seed)).verify(
        ed.signature(msg, seed, cpub), msg)  # raises if invalid


def test_receipt_pure_signature_verifies_through_receipt_verifier():
    import invoice_audit.receipt as R
    from invoice_audit import _ed25519_pure as ed
    seed = bytes(range(1, 33))
    body = {"schema": SCHEMA, "scans": [], "pricebook": {}, "n": 42}
    canon = R._canonical(body)
    pub = ed.publickey(seed)
    sig = ed.signature(canon, seed, pub)
    assert ed.checkvalid(sig, canon, pub) is True
    # a pure-backend signature must verify through receipt's verifier
    assert R._verify_sig(pub, canon, sig) is True
    # and a tampered body must fail
    bad = R._canonical({**body, "n": 43})
    assert R._verify_sig(pub, bad, sig) is False


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
        passed += 1
    print(f"\n{passed}/{len(fns)} passed")
