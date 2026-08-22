"""Per-site pins for the invoice-audit engine. Run: python3 -m pytest tests/ -q
(or python3 tests/test_invoice_audit.py to run without pytest).

Each stage is pinned independently; the end-to-end test asserts the three
planted cases (overcharge / arithmetic / no-reference) each flag, by name.
"""
from __future__ import annotations

import json
import base64
import hashlib
import os
import shutil
import subprocess
import sqlite3
import sys
import tempfile
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from invoice_audit.analytics import (  # noqa: E402
    analytics_text, business_history, category_summary, export_csv,
    history_text, integration_payload, send_webhook, slack_payload, vendor_summary, write_email_draft,
    write_html_report, write_integration_payload)
from invoice_audit.analyst import answer_question  # noqa: E402
from invoice_audit.audit import audit_folder  # noqa: E402
from invoice_audit.categories import classify_item  # noqa: E402
from invoice_audit.connectors import (  # noqa: E402
    ConnectorConfig, connector_presets, sync_connector, write_connector_config)
from invoice_audit.data_quality import (  # noqa: E402
    data_quality_report, normalize_invoice_date)
from invoice_audit.floor import Floor, Rule  # noqa: E402
from invoice_audit.grounding import (  # noqa: E402
    GROUND_CONFIDENCE, ground_line, stated_total_reconciles)
from invoice_audit.layout import LineItem, ParsedInvoice, parse_invoice  # noqa: E402
from invoice_audit.legacy_bridge import summarize_processes  # noqa: E402
from invoice_audit.ocr import AuditError, Token  # noqa: E402
from invoice_audit.pricebook import PriceBook, ReferenceRow  # noqa: E402
from invoice_audit.receipt import sign_receipt, verify_receipt, SCHEMA  # noqa: E402
from invoice_audit.kist_bridge import (  # noqa: E402
    KistResearchError, MarketQuote, research_price, _extract_json)
from invoice_audit.benchmark import (  # noqa: E402
    items_from_receipt, refresh_all, refresh_item)
from invoice_audit.savings import savings_report, savings_text  # noqa: E402
from invoice_audit.pricebook import PriceBook  # noqa: E402
from invoice_audit.primitives import (  # noqa: E402
    Permission, REGISTRY, VerificationResult,
    primitives as list_primitives, verify as verify_primitive)
from invoice_audit.invariants import (  # noqa: E402
    build_invariants, check_invariants, INVARIANTS_VERSION)
from contextlib import contextmanager  # noqa: E402


@contextmanager
def _kist_fixture(mapping: dict):
    """Point kist_bridge at an in-test fixture map (offline, deterministic)."""
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "kfix.json"
        p.write_text(json.dumps(mapping))
        old = os.environ.get("INVOICE_AUDIT_KIST_FIXTURE")
        os.environ["INVOICE_AUDIT_KIST_FIXTURE"] = str(p)
        try:
            yield
        finally:
            if old is None:
                os.environ.pop("INVOICE_AUDIT_KIST_FIXTURE", None)
            else:
                os.environ["INVOICE_AUDIT_KIST_FIXTURE"] = old


_PUMP = {"unit_price_usd": 3200.0, "low_usd": 2900, "high_usd": 3600,
         "confidence": 0.72, "models": ["opus", "gemini", "deepseek"],
         "sources": ["https://example.com/pumps"], "notes": "median of 3"}
from invoice_audit.store import connect, count_rows, list_findings, store_receipt  # noqa: E402
from invoice_audit.validate import arithmetic_flags  # noqa: E402
from invoice_audit.watcher import run_once_if_changed, source_fingerprint  # noqa: E402

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


def test_pricebook_loads_excel_sheets():
    from invoice_audit.layout import LineItem
    sheet = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1">
      <c r="A1" t="inlineStr"><is><t>Part Number</t></is></c>
      <c r="B1" t="inlineStr"><is><t>Item Description</t></is></c>
      <c r="C1" t="inlineStr"><is><t>Unit Cost</t></is></c>
    </row>
    <row r="2">
      <c r="A2" t="inlineStr"><is><t>HYD-4410</t></is></c>
      <c r="B2" t="inlineStr"><is><t>HYDRAULIC PUMP ASSY</t></is></c>
      <c r="C2"><v>2950</v></c>
    </row>
  </sheetData>
</worksheet>
"""
    with tempfile.TemporaryDirectory() as d:
        xlsx = Path(d) / "price-sheet.xlsx"
        with zipfile.ZipFile(xlsx, "w") as zf:
            zf.writestr("xl/worksheets/sheet1.xml", sheet)
        book = PriceBook.load(xlsx)
        line = LineItem("HYD-4410", "HYDRAULIC PUMP ASSY", 1, 5980.0, 5980.0, 0.99)
        assert book.check(line)["verdict"] == "overcharge-flag"


def test_legacy_bridge_process_parser_detects_perslis_vm_and_rm():
    ps_text = """
      PID COMMAND
      101 /Users/lukekist/.kist/apps/desktop-vision-console/server.py --port 8765
      102 /Users/lukekist/Library/Application Support/LIST Enterprise/Perslis Bridge/current/perslis-bridge
      103 /Users/lukekist/.perslis/bin/perslis-agent-gateway mcp-serve
      104 /usr/bin/python3 /Users/lukekist/.kist/apps/desktop-vision-console/vm_guest_mcp.py
      105 /opt/homebrew/bin/qemu-system-aarch64 -name ghostbridge-win11-power-terminal -qmp unix:/private/tmp/win11/qmp.sock,server,nowait
      106 /opt/homebrew/bin/qemu-system-i386 -name legacy-win95 -qmp unix:/private/tmp/win95/qmp.sock,server,nowait
      107 /opt/homebrew/bin/qemu-system-i386 -name ghostbridge-win98-native-drop -qmp unix:/private/tmp/win98/qmp.sock,server,nowait
    """
    summary = summarize_processes(ps_text)
    counts = summary["counts"]
    assert counts["desktopVision"] == 1
    assert counts["perslisBridge"] == 1
    assert counts["perslisRuntime"] == 1
    assert counts["rmBridge"] == 2
    assert counts["win11Vm"] == 1
    assert counts["legacyWin95Vm"] == 1
    assert counts["legacyWin98Vm"] == 1
    sockets = {item["qmpSocket"] for item in summary["items"] if item["qmpSocket"]}
    assert "/private/tmp/win11/qmp.sock" in sockets
    assert "/private/tmp/win95/qmp.sock" in sockets
    assert "/private/tmp/win98/qmp.sock" in sockets


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


def test_receipt_carries_ocr_row_text_for_conversion_view():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    first_line = receipt["invoices"][0]["lines"][0]
    assert "HYD-4410" in first_line["ocr_row_text"]
    assert "$5,980.00" in first_line["ocr_row_text"]


def test_receipt_carries_line_and_invoice_categories():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    inv71 = next(i for i in receipt["invoices"] if i["file"] == "invoice-30071.png")
    inv72 = next(i for i in receipt["invoices"] if i["file"] == "invoice-30072.png")
    inv73 = next(i for i in receipt["invoices"] if i["file"] == "invoice-30073.png")

    assert inv71["category"] == "Hydraulics"
    assert inv72["category"] == "Cement & Aggregates"
    assert inv73["category"] == "Forklift & Material Handling"

    by_sku = {
        line["sku"]: line
        for inv in receipt["invoices"]
        for line in inv["lines"]
    }
    assert by_sku["HYD-4410"]["category"] == "Hydraulics"
    assert by_sku["SEN-7781"]["category"] == "Sensors & Controls"
    assert by_sku["SEN-7781"]["policy_delta_total"] == 168.0
    assert classify_item("SEN-7781", "PROXIMITY SENSOR HD",
                         "YANKEE FORKLIFT PARTS CO")["category"] == "Sensors & Controls"


def test_receipt_orders_invoices_chronologically_and_reports_data_rot():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    assert [inv["date"] for inv in receipt["invoices"]] == [
        "2026-08-12", "2026-08-14", "2026-08-17",
    ]
    assert receipt["dataQuality"]["issueCount"] == 0
    assert receipt["dataQuality"]["timeline"][0]["invoice"] == "invoice-30071.png"
    assert normalize_invoice_date("08/12/26") == "2026-08-12"

    rot = data_quality_report([
        {"file": "a.png", "vendor": "V", "invoice_no": "1", "date": "UNKNOWN"},
        {"file": "b.png", "vendor": "V", "invoice_no": "1", "date": "2099-01-01"},
    ])
    kinds = {issue["kind"] for issue in rot["issues"]}
    assert "missing-or-unreadable-date" in kinds
    assert "future-dated-invoice" in kinds
    assert "duplicate-invoice-number" in kinds


def test_optional_market_pricing_adds_human_review_flags():
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        market = Path(d) / "market.csv"
        market.write_text(
            "sku,description,unit_price,date\n"
            "HYD-4410,HYDRAULIC PUMP ASSY,3000.00,2026-08-01\n"
            "FLT-2200,FORKLIFT BRAKE KIT,412.50,2026-08-01\n"
            "OIL-0055,FORM OIL 55 GAL DRUM,289.00,2026-08-01\n"
            "RBR-0620,REBAR #6 20FT BUNDLE,184.00,2026-08-01\n"
            "CEM-0094,PORTLAND CEMENT T-I/II PALLET,612.00,2026-08-01\n"
            "SEN-7781,PROXIMITY SENSOR HD,60.00,2026-08-01\n"
        )
        receipt = audit_folder(
            DEMO / "scans",
            DEMO / "pricebook.csv",
            floor_path=DEMO / "floor-rules.json",
            market_path=market,
        )
        kinds = {(item["invoice"], item["kind"]) for item in receipt["reviewQueue"]}
        assert ("invoice-30071.png", "market-overcharge-flag") in kinds
        assert ("invoice-30073.png", "market-overcharge-flag") in kinds
        assert receipt["totals"]["marketOverchargeUSD"] > 0
        assert receipt["marketPricebook"]["rows"] == 6
        assert verify_receipt(receipt, rehash_inputs=True) == []
        market.write_text(market.read_text() + "NEW-1,NEW,1.00,2026-08-01\n")
        assert "market-pricebook-hash-changed:market.csv" in verify_receipt(
            receipt, rehash_inputs=True)


def test_llm_extraction_review_flags_disagreement_for_human():
    _ensure_fixtures()
    base = audit_folder(DEMO / "scans", DEMO / "pricebook.csv")
    fixture = {}
    for inv in base["invoices"]:
        fixture[inv["file"]] = {
            "invoice_no": inv["invoice_no"],
            "lines": [
                {
                    "sku": line["sku"],
                    "description": line["description"],
                    "qty": line["qty"],
                    "unit_price": line["unit_price"],
                    "line_total": line["line_total"],
                }
                for line in inv["lines"]
            ],
        }
    fixture["invoice-30072.png"]["lines"] = []
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "llm.json"
        path.write_text(json.dumps(fixture))
        prev = os.environ.get("INVOICE_AUDIT_LLM_FIXTURE")
        os.environ["INVOICE_AUDIT_LLM_FIXTURE"] = str(path)
        try:
            receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv")
        finally:
            if prev is None:
                os.environ.pop("INVOICE_AUDIT_LLM_FIXTURE", None)
            else:
                os.environ["INVOICE_AUDIT_LLM_FIXTURE"] = prev
    kinds = {(item["invoice"], item["kind"]) for item in receipt["reviewQueue"]}
    assert ("invoice-30072.png", "llm-line-count-disagreement") in kinds


def test_pdf_input_renders_to_ocr_image_and_keeps_source_trace():
    _ensure_fixtures()
    from PIL import Image

    with tempfile.TemporaryDirectory() as d:
        scans = Path(d)
        pdf = scans / "invoice-30072.pdf"
        Image.open(DEMO / "scans" / "invoice-30072.png").save(pdf, "PDF", resolution=200)

        receipt = audit_folder(scans, DEMO / "pricebook.csv")
        assert receipt["totals"]["invoices"] == 1
        scan = receipt["scans"][0]
        assert scan["source_kind"] == "pdf"
        assert scan["source_path"] == str(pdf)
        assert scan["source_page"] == 1
        assert Path(scan["path"]).suffix == ".png"
        assert verify_receipt(receipt, rehash_inputs=True) == []

        pdf.write_bytes(pdf.read_bytes() + b"\n% tamper")
        assert f"source-hash-changed:{pdf.name}" in verify_receipt(
            receipt, rehash_inputs=True)


def test_sql_store_persists_receipt_findings_and_trace_claims():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    with tempfile.TemporaryDirectory() as d:
        db = Path(d) / "business.sqlite"
        with connect(db) as con:
            receipt_id = store_receipt(con, receipt)
            counts = count_rows(con, [
                "receipts", "source_files", "invoices", "invoice_lines",
                "findings", "business_claims",
            ])
            assert receipt_id == 1
            assert counts["receipts"] == 1
            assert counts["source_files"] == 5  # 3 scans + pricebook + rules
            assert counts["invoices"] == 3
            assert counts["invoice_lines"] == 7
            assert counts["findings"] == 6
            assert counts["business_claims"] == 66  # 9 claims per line + 3 invoices

            findings = list_findings(con)
            assert findings[0]["kind"] == "overcharge-flag"
            assert findings[0]["severity"] == "money"
            assert findings[0]["sku"] == "HYD-4410"
            assert findings[0]["category"] == "Hydraulics"

            claim = con.execute(
                """
                SELECT object, jeeves_verdict, prel_trace_json, evidence_json
                FROM business_claims
                WHERE relation = 'has_unit_price' AND object = '5980.0'
                """
            ).fetchone()
            assert claim is not None
            assert claim["jeeves_verdict"] == "consistent"
            assert "HYD-4410" in claim["prel_trace_json"]
            assert "invoice-30071.png" in claim["evidence_json"]

            category_claim = con.execute(
                """
                SELECT object, prel_trace_json
                FROM business_claims
                WHERE relation = 'belongs_to_category'
                  AND object = 'Sensors & Controls'
                """
            ).fetchone()
            assert category_claim is not None
            assert "SEN-7781" in category_claim["prel_trace_json"]


def test_sql_migration_adds_category_columns_before_indexes():
    with tempfile.TemporaryDirectory() as d:
        db = Path(d) / "old.sqlite"
        old = sqlite3.connect(db)
        old.executescript(
            """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE receipts (
                id INTEGER PRIMARY KEY,
                schema TEXT NOT NULL,
                generated_at TEXT NOT NULL,
                signature TEXT NOT NULL UNIQUE,
                public_key TEXT NOT NULL,
                receipt_json TEXT NOT NULL
            );
            CREATE TABLE source_files (
                id INTEGER PRIMARY KEY,
                receipt_id INTEGER NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                rows INTEGER,
                UNIQUE(receipt_id, kind, path)
            );
            CREATE TABLE invoices (
                id INTEGER PRIMARY KEY,
                receipt_id INTEGER NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
                source_file_id INTEGER REFERENCES source_files(id) ON DELETE SET NULL,
                file_name TEXT NOT NULL,
                path TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                vendor TEXT NOT NULL,
                invoice_no TEXT NOT NULL,
                invoice_date TEXT NOT NULL,
                stated_total REAL,
                stated_total_reconciles INTEGER NOT NULL,
                disposition TEXT NOT NULL
            );
            CREATE TABLE invoice_lines (
                id INTEGER PRIMARY KEY,
                invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
                line_index INTEGER NOT NULL,
                sku TEXT NOT NULL,
                description TEXT NOT NULL,
                qty REAL NOT NULL,
                unit_price REAL NOT NULL,
                line_total REAL NOT NULL,
                ocr_row_text TEXT NOT NULL,
                ocr_min_confidence REAL NOT NULL,
                price_verdict TEXT NOT NULL,
                grounding_verdict TEXT NOT NULL,
                floor_verdict TEXT NOT NULL,
                matched_on TEXT,
                reference_median REAL,
                delta_total REAL NOT NULL,
                trace_json TEXT NOT NULL,
                UNIQUE(invoice_id, line_index)
            );
            CREATE TABLE findings (
                id INTEGER PRIMARY KEY,
                receipt_id INTEGER NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
                invoice_id INTEGER REFERENCES invoices(id) ON DELETE CASCADE,
                line_id INTEGER REFERENCES invoice_lines(id) ON DELETE SET NULL,
                kind TEXT NOT NULL,
                severity TEXT NOT NULL,
                detail TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'open',
                evidence_json TEXT NOT NULL
            );
            CREATE TABLE business_claims (
                id INTEGER PRIMARY KEY,
                receipt_id INTEGER NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
                subject TEXT NOT NULL,
                relation TEXT NOT NULL,
                object TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_ref TEXT NOT NULL,
                jeeves_verdict TEXT NOT NULL,
                prel_trace_json TEXT NOT NULL,
                evidence_json TEXT NOT NULL
            );
            """
        )
        old.close()

        with connect(db) as con:
            invoice_cols = {
                row["name"] for row in con.execute("PRAGMA table_info(invoices)")
            }
            line_cols = {
                row["name"] for row in con.execute("PRAGMA table_info(invoice_lines)")
            }
            indexes = {
                row["name"] for row in con.execute("PRAGMA index_list(invoice_lines)")
            }
            assert "category" in invoice_cols
            assert "category" in line_cols
            assert "policy_delta_total" in line_cols
            assert "idx_invoice_lines_category" in indexes


def test_sql_backed_analyst_answers_with_citations():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    with tempfile.TemporaryDirectory() as d:
        with connect(Path(d) / "business.sqlite") as con:
            store_receipt(con, receipt)
            summary = answer_question(con, "give me a business summary")
            assert "invoices: 3" in summary
            assert "potential overcharge: $6,060.00" in summary

            exposure = answer_question(con, "show overcharges")
            assert "Money exposure" in exposure
            assert "invoice-30071.png" in exposure
            assert "invoice unit $5,980.00" in exposure
            assert "historical median $2,950.00" in exposure
            assert "variance +102.7%" in exposure
            assert "exposure $6,060.00" in exposure
            assert "source:" in exposure

            trace = answer_question(con, "trace this dollar")
            assert "Follow the dollar" in trace
            assert "$6,060.00 potential exposure" in trace
            assert "PO → job/customer → payment/bank → recovery status" in trace

            why = answer_question(con, "why was invoice-30073 flagged?")
            assert "Findings for invoice-30073.png" in why
            assert "floor-veto" in why

            categories = answer_question(con, "show all invoices by category")
            assert "Invoice category map" in categories
            assert "Sensors & Controls" in categories

            profit = answer_question(con, "where are we making the most money?")
            assert "not enough source data connected yet" in profit


def test_analytics_exports_and_visual_report_map_business_exposure():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        with connect(root / "business.sqlite") as con:
            store_receipt(con, receipt)
            cats = {row["category"]: row for row in category_summary(con)}
            assert cats["Hydraulics"]["total_exposure"] == 6060.0
            assert cats["Sensors & Controls"]["policy_exposure"] == 168.0

            vendors = {row["vendor"]: row for row in vendor_summary(con)}
            assert vendors["HARTFORD HYDRAULICS INC"]["total_exposure"] == 6060.0
            assert vendors["NUTMEG CONCRETE SUPPLY"]["category"] == "Cement & Aggregates"

            text = analytics_text(con)
            assert "potential exposure: $6,228.00" in text
            assert "Profit/revenue note" in text

            journal = business_history(con)
            assert journal["status"] == "SOS: money at risk"
            assert journal["overview"]["total_exposure"] == 6228.0
            assert journal["recent_runs"][0]["invoices"] == 3
            assert journal["attention"][0]["title"] == "HOLD $6,060.00 UNTIL REVIEWED"
            assert journal["attention"][0]["action"] == "Trace dollars"
            assert "Trace largest exposure" in journal["next_actions"][0]
            assert "SOS Attention Journal" in history_text(con)

            report = write_html_report(con, root / "business-report.html")
            html = report.read_text()
            assert "Financial Ops Copilot Business Map" in html
            assert "Where money is leaking by category" in html
            assert "Sensors &amp; Controls" in html

            outputs = export_csv(con, root / "exports")
            assert {p.name for p in outputs} == {
                "category_summary.csv", "vendor_summary.csv",
                "finding_summary.csv", "invoice_lines.csv",
                "top_findings.csv",
            }
            assert "Hydraulics" in (root / "exports" / "category_summary.csv").read_text()

            payload = slack_payload(con)
            assert "Financial Ops Copilot: 3 invoices" in payload["text"]
            assert "$6,228.00 potential exposure" in payload["text"]


def test_share_outputs_create_boss_email_and_api_payload():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        with connect(root / "business.sqlite") as con:
            store_receipt(con, receipt)
            report = write_html_report(con, root / "business-report.html")
            email = write_email_draft(
                con,
                root / "boss-summary.eml",
                to_addr="boss@example.com",
                attach_report=report,
            )
            payload_path = write_integration_payload(con, root / "api-payload.json")

            email_text = email.read_text()
            assert "Subject: Financial Ops Copilot Summary" in email_text
            assert "boss@example.com" in email_text
            assert "Financial Ops Copilot" in email_text
            assert "business-report.html" in email_text

            payload = json.loads(payload_path.read_text())
            assert payload["event_type"] == "invoice_audit.business_report.v1"
            assert payload["overview"]["total_exposure"] == 6228.0
            assert payload["categories"][0]["category"] == "Hydraulics"
            assert "Financial Ops Copilot" in payload["message"]


def test_webhook_sender_posts_business_report_json():
    _ensure_fixtures()
    receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv",
                           floor_path=DEMO / "floor-rules.json")
    received: dict[str, object] = {}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers["Content-Length"])
            received["content_type"] = self.headers["Content-Type"]
            received["payload"] = json.loads(self.rfile.read(length))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, format, *args):  # noqa: A002
            return

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory() as d:
            with connect(Path(d) / "business.sqlite") as con:
                store_receipt(con, receipt)
                payload = integration_payload(con)
                assert payload["overview"]["total_exposure"] == 6228.0
                result = send_webhook(
                    con,
                    f"http://127.0.0.1:{server.server_port}/zapier",
                    timeout=5,
                )
                assert result["ok"] is True
                assert result["status"] == 200
    finally:
        server.server_close()
        thread.join(timeout=5)

    assert received["content_type"] == "application/json"
    posted = received["payload"]
    assert posted["event_type"] == "invoice_audit.business_report.v1"
    assert posted["overview"]["findings"] == 6


def test_connector_syncs_local_or_network_folder_to_managed_workspace():
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        config = write_connector_config(
            ConnectorConfig(
                kind="network-folder",
                name="Plant AP",
                invoices=str(DEMO / "scans"),
                pricebook=str(DEMO / "pricebook.csv"),
                floor=str(DEMO / "floor-rules.json"),
            ),
            root / "source.json",
        )
        manifest = sync_connector(config, root / "workspace")
        assert Path(manifest["scans_dir"]).is_dir()
        assert Path(manifest["pricebook"]).exists()
        assert Path(manifest["floor"]).exists()
        assert sum(1 for f in manifest["files"] if f["role"] == "invoice") == 3
        assert any(p["kind"] == "quickbooks" for p in connector_presets())


def test_connector_syncs_api_json_for_zapier_style_pull():
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        payload = {
            "files": [
                {
                    "role": "invoice",
                    "name": "invoice-30072.png",
                    "content_base64": base64.b64encode(
                        (DEMO / "scans" / "invoice-30072.png").read_bytes()
                    ).decode("ascii"),
                }
            ],
            "pricebook_csv": (DEMO / "pricebook.csv").read_text(),
        }
        api = root / "api.json"
        api.write_text(json.dumps(payload))
        config = write_connector_config(
            ConnectorConfig(
                kind="api-json",
                name="Zapier Pull",
                url=api.as_uri(),
            ),
            root / "source.json",
        )
        manifest = sync_connector(config, root / "workspace")
        assert Path(manifest["pricebook"]).exists()
        invoices = [f for f in manifest["files"] if f["role"] == "invoice"]
        assert len(invoices) == 1
        assert invoices[0]["name"] == "invoice-30072.png"


def test_watch_once_skips_unchanged_inputs_and_reacts_to_source_change():
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pricebook = root / "pricebook.csv"
        pricebook.write_text((DEMO / "pricebook.csv").read_text())
        db = root / "business.sqlite"
        state = root / "watch-state.json"
        receipt = root / "latest-receipt.json"

        fp1 = source_fingerprint(DEMO / "scans", pricebook)
        first = run_once_if_changed(
            DEMO / "scans", pricebook, db, state_path=state,
            receipt_path=receipt)
        second = run_once_if_changed(
            DEMO / "scans", pricebook, db, state_path=state,
            receipt_path=receipt)
        assert first["changed"] is True
        assert first["fingerprint"] == fp1
        assert second == {
            "changed": False,
            "fingerprint": fp1,
            "reason": "inputs-unchanged",
        }

        pricebook.write_text(pricebook.read_text() + "NEW-1,NEW ITEM,1.00,2026-08-20\n")
        third = run_once_if_changed(
            DEMO / "scans", pricebook, db, state_path=state,
            receipt_path=receipt)
        assert third["changed"] is True
        assert third["fingerprint"] != fp1
        with connect(db) as con:
            assert count_rows(con, ["receipts"])["receipts"] == 2


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


# ---------------------------------------------------------------------------
# Industry benchmark (kist research) + savings story — per-site invariants.
# ---------------------------------------------------------------------------

def test_kist_bridge_fixture_parses_cross_model_quote():
    with _kist_fixture({"HYD-4410|HYDRAULIC PUMP ASSY": _PUMP}):
        q = research_price("HYD-4410", "HYDRAULIC PUMP ASSY", mode="dig")
    assert isinstance(q, MarketQuote)
    assert q.unit_price_usd == 3200.0
    assert q.low_usd == 2900.0 and q.high_usd == 3600.0
    assert q.models_consulted == ["opus", "gemini", "deepseek"]
    assert q.provenance == "fixture"  # honest: never dressed up as live


def test_kist_bridge_fails_closed_with_named_reason_per_case():
    # Each failure mode returns a DISTINCT machine-readable reason — never a price.
    cases = {
        "kist-fixture-no-entry": ("NOPE", "does not exist", {"X|Y": _PUMP}),
        "kist-missing-price": ("A", "b", {"A|b": {"unit_price_usd": None}}),
        "kist-nonpositive-price": ("A", "b", {"A|b": {"unit_price_usd": 0}}),
        "kist-bad-price": ("A", "b", {"A|b": {"unit_price_usd": "free"}}),
    }
    for expected_reason, (sku, desc, mapping) in cases.items():
        with _kist_fixture(mapping):
            try:
                research_price(sku, desc)
                assert False, f"{expected_reason} should have raised"
            except KistResearchError as e:
                assert e.reason == expected_reason, (expected_reason, e.reason)


def test_kist_bridge_binary_absent_fails_closed():
    old = os.environ.get("INVOICE_AUDIT_KIST_BIN")
    os.environ["INVOICE_AUDIT_KIST_BIN"] = "kist-does-not-exist-xyz"
    os.environ.pop("INVOICE_AUDIT_KIST_FIXTURE", None)
    try:
        research_price("A", "b")
        assert False, "absent binary should fail closed"
    except KistResearchError as e:
        assert e.reason == "kist-binary-not-found"
    finally:
        if old is None:
            os.environ.pop("INVOICE_AUDIT_KIST_BIN", None)
        else:
            os.environ["INVOICE_AUDIT_KIST_BIN"] = old


def test_kist_bridge_extracts_last_json_block_and_flags_no_json():
    stream = ('model A says ```json\n{"unit_price_usd": 10}\n```\n'
              'synthesis ```json\n{"unit_price_usd": 42}\n```\n')
    assert _extract_json(stream)["unit_price_usd"] == 42  # last block wins
    try:
        _extract_json("no json here at all")
        assert False, "should raise kist-no-json"
    except KistResearchError as e:
        assert e.reason == "kist-no-json"


def test_benchmark_refresh_writes_pricebook_shape_and_fails_closed_per_item():
    with tempfile.TemporaryDirectory() as d, _kist_fixture({"HYD-4410|HYDRAULIC PUMP ASSY": _PUMP}):
        items = [("HYD-4410", "HYDRAULIC PUMP ASSY"), ("FLT-2200", "FORKLIFT BRAKE KIT")]
        r = refresh_all(items, d, mode="dig")
        assert r.researched == 1 and len(r.quotes) == 1
        # The un-researchable item is LEFT OUT and named — never invented.
        assert any(f["sku"] == "FLT-2200" and f["reason"] == "kist-fixture-no-entry"
                   for f in r.failures)
        # CSV is PriceBook-compatible and loads.
        book = PriceBook.load(Path(d) / "market-pricebook.csv")
        assert len(book.rows) == 1
        # Sidecar carries provenance for the receipt.
        side = json.loads((Path(d) / "market-benchmarks.json").read_text())
        assert side["count"] == 1
        assert side["benchmarks"][0]["provenance"] == "fixture"


def test_benchmark_cache_reuses_fresh_then_force_reresearches():
    with tempfile.TemporaryDirectory() as d, _kist_fixture({"HYD-4410|HYDRAULIC PUMP ASSY": _PUMP}):
        items = [("HYD-4410", "HYDRAULIC PUMP ASSY")]
        first = refresh_all(items, d, mode="dig")
        assert first.researched == 1 and first.reused == 0
        second = refresh_all(items, d, mode="dig")          # cache hit
        assert second.researched == 0 and second.reused == 1
        forced = refresh_all(items, d, mode="dig", force=True)  # ignore cache
        assert forced.researched == 1 and forced.reused == 0


def test_benchmark_refresh_item_forces_fresh_live_quote():
    with tempfile.TemporaryDirectory() as d, _kist_fixture({"HYD-4410|HYDRAULIC PUMP ASSY": _PUMP}):
        q = refresh_item("HYD-4410", "HYDRAULIC PUMP ASSY", d, mode="dig")
        assert q.unit_price_usd == 3200.0
        assert (Path(d) / "market-pricebook.csv").exists()


def test_benchmark_items_from_receipt_are_distinct():
    receipt = {"invoices": [
        {"lines": [{"sku": "A", "description": "x"}, {"sku": "A", "description": "x"}]},
        {"lines": [{"sku": "B", "description": "y"}, {"sku": "", "description": ""}]},
    ]}
    assert items_from_receipt(receipt) == [("A", "x"), ("B", "y")]


def _savings_fixture_receipt() -> dict:
    return {
        "totals": {"invoices": 3, "linesChecked": 7, "flagged": 4,
                   "potentialOverchargeUSD": 6060.0, "marketOverchargeUSD": 2780.0,
                   "policyOverageUSD": 120.0, "dataQualityIssues": 1},
        "reviewQueue": [
            {"invoice": "i1", "kind": "overcharge-flag", "line": 0, "detail": "hist"},
            {"invoice": "i1", "kind": "market-overcharge-flag", "line": 0, "detail": "mkt"},
            {"invoice": "i2", "kind": "no-reference", "line": 1, "detail": "no hist"},
            {"invoice": "i3", "kind": "market-no-reference", "line": 0, "detail": "no mkt"},
        ],
    }


def test_savings_report_sums_money_caught_per_source():
    r = savings_report(_savings_fixture_receipt())
    # Money caught = history + industry benchmark + policy, each pinned by name.
    assert r["breakdown"]["priceHistoryUSD"] == 6060.0
    assert r["breakdown"]["industryBenchmarkUSD"] == 2780.0
    assert r["breakdown"]["policyUSD"] == 120.0
    # HARD RULE: banked money = DETERMINISTIC-only (own history + policy). The
    # ML-researched industry number is a review signal, NEVER banked.
    assert r["moneyCaughtUSD"] == 6180.0                      # 6060 history + 120 policy
    assert r["industryReviewSignalUSD"] == 2780.0            # surfaced, not summed
    assert r["flagsFound"] == 4
    # "Things you'd have missed" surfaced per source.
    assert r["itemsSurfaced"]["noPriceHistory"] == 1
    assert r["itemsSurfaced"]["noIndustryBenchmark"] == 1
    assert r["itemsSurfaced"]["dataQuality"] == 1
    assert "industry" in r["headline"].lower()
    assert "6,180" in savings_text(_savings_fixture_receipt())


def test_savings_never_banks_ml_industry_even_when_larger():
    # The exact leak: when the kist-researched (ML) industry overpay is BIGGER
    # than the deterministic history, it must STILL never enter the banked figure.
    ml_bigger = {
        "totals": {"invoices": 1, "linesChecked": 1, "flagged": 1,
                   "potentialOverchargeUSD": 100.0, "marketOverchargeUSD": 9000.0,
                   "policyOverageUSD": 0.0, "dataQualityIssues": 0},
        "reviewQueue": [
            {"invoice": "i1", "kind": "market-overcharge-flag", "line": 0, "detail": "ml"},
        ],
    }
    r = savings_report(ml_bigger)
    assert r["moneyCaughtUSD"] == 100.0            # deterministic history ONLY
    assert r["moneyCaughtUSD"] != 9000.0           # ML value never banked
    assert r["industryReviewSignalUSD"] == 9000.0  # it lives here instead
    # And the human-facing text must not present the ML figure as banked money.
    txt = savings_text(ml_bigger)
    assert "NOT banked" in txt


def test_savings_clean_receipt_has_zero_caught_and_clean_headline():
    clean = {"totals": {"invoices": 2, "linesChecked": 4, "flagged": 0},
             "reviewQueue": []}
    r = savings_report(clean)
    assert r["moneyCaughtUSD"] == 0.0
    assert "clean" in r["headline"].lower()


def test_receipt_binds_and_verifies_market_benchmarks_sidecar():
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d, _kist_fixture({
        "HYD-4410|HYDRAULIC PUMP ASSY": _PUMP,
        "FLT-2200|FORKLIFT BRAKE KIT": {"unit_price_usd": 400.0},
        "SEN-7781|PROXIMITY SENSOR HD": {"unit_price_usd": 60.0},
    }):
        # kist research → market CSV + provenance sidecar.
        items = [("HYD-4410", "HYDRAULIC PUMP ASSY"),
                 ("FLT-2200", "FORKLIFT BRAKE KIT"),
                 ("SEN-7781", "PROXIMITY SENSOR HD")]
        bench = refresh_all(items, d, mode="dig")
        receipt = audit_folder(
            DEMO / "scans", DEMO / "pricebook.csv",
            floor_path=DEMO / "floor-rules.json",
            market_path=bench.market_csv,
            market_benchmarks_path=bench.sidecar,
        )
        # Provenance is bound into the signed receipt and verifies.
        assert "marketBenchmarks" in receipt
        assert verify_receipt(receipt, rehash_inputs=True) == []
        # Per-site tamper detection: BOTH the market CSV and the sidecar are pinned.
        Path(bench.market_csv).write_text(Path(bench.market_csv).read_text() + "Z,z,1.00\n")
        assert "market-pricebook-hash-changed:market-pricebook.csv" in verify_receipt(receipt)
        Path(bench.sidecar).write_text(Path(bench.sidecar).read_text() + " ")
        assert "market-benchmarks-hash-changed:market-benchmarks.json" in verify_receipt(receipt)


# ---------------------------------------------------------------------------
# Primitive registry — `verify` is the template contract every surface consumes.
# ---------------------------------------------------------------------------

def test_verify_primitive_returns_full_contract_shape():
    r = sign_receipt({"schema": SCHEMA, "scans": [], "pricebook": {}, "n": 1})
    res = verify_primitive(r, rehash_inputs=False)
    assert isinstance(res, VerificationResult)
    # The fixed categories are ALWAYS present.
    assert res.ok is True
    assert res.problems == []
    assert res.provenance["signatureChecked"] is True
    # rehash OFF → nothing was re-hashed → provenance claims nothing was.
    assert res.provenance["rehashedInputs"] is False
    assert res.provenance["reHashed"] == {}
    assert res.rule_version == "invoice-audit.verify.v1"
    assert res.timestamp.endswith("Z")
    # The authoritative result matches the deterministic core EXACTLY — the
    # primitive standardizes reporting, it never changes the verdict.
    assert res.ok == (verify_receipt(r, rehash_inputs=False) == [])


def test_verify_primitive_never_raises_on_hostile_shapes():
    # A signed receipt the CORE verifies (rehash off) must never crash the
    # provenance builder — the wrapper is at least as robust as what it wraps.
    r = sign_receipt({"schema": SCHEMA, "scans": ["a.png"], "pricebook": "notadict"})
    core = verify_receipt(r, rehash_inputs=False)
    res = verify_primitive(r, rehash_inputs=False)      # must NOT raise
    assert isinstance(res, VerificationResult)
    assert res.ok == (core == [])
    assert res.problems == core


def test_verify_primitive_rehash_parity_and_honest_provenance():
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        scans = Path(d) / "scans"
        shutil.copytree(DEMO / "scans", scans)
        receipt = audit_folder(scans, DEMO / "pricebook.csv")
        res = verify_primitive(receipt, rehash_inputs=True)
        assert res.ok is True
        # Provenance reflects what was ACTUALLY re-hashed, keyed by the real path.
        assert res.provenance["reHashed"]["scans"] == [s["path"] for s in receipt["scans"]]
        assert res.provenance["reHashed"]["pricebook"] == receipt["pricebook"]["path"]
        # Tamper a scan on disk → core reports hash-changed; primitive matches.
        Path(receipt["scans"][0]["path"]).write_bytes(b"corrupt")
        core = verify_receipt(receipt, rehash_inputs=True)
        tampered = verify_primitive(receipt, rehash_inputs=True)
        assert tampered.ok is False
        assert any("hash-changed" in p for p in tampered.problems)
        assert tampered.problems == core               # never diverges from core


def test_verify_primitive_unsigned_parity():
    r = {"schema": SCHEMA, "scans": [], "pricebook": {}}  # no signature at all
    res = verify_primitive(r, rehash_inputs=False)
    assert res.ok is False
    assert "receipt-unsigned" in res.problems
    assert res.problems == verify_receipt(r, rehash_inputs=False)


def test_verify_cli_json_exits_zero_on_tamper_and_carries_problems():
    # Cross the CLI-exit -> consumer seam: --json must exit 0 and put the verdict
    # in `ok`, so a real tamper surfaces as structured problems, not a process
    # failure that a consumer (Swift) would misclassify as "Failed".
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        receipt = audit_folder(DEMO / "scans", DEMO / "pricebook.csv")
        receipt["totals"]["flagged"] = 999            # tamper the signed body
        rpath = Path(d) / "tampered.json"
        rpath.write_text(json.dumps(receipt))
        proc = subprocess.run(
            [sys.executable, "-m", "invoice_audit", "verify", str(rpath), "--json"],
            cwd=str(ROOT), env={**os.environ, "PYTHONPATH": str(ROOT)},
            capture_output=True, text=True)
        assert proc.returncode == 0, proc.stderr       # exit 0 even when not ok
        out = json.loads(proc.stdout)
        assert out["ok"] is False
        assert "receipt-signature-invalid" in out["problems"]


def test_verify_primitive_flags_tamper_matching_core():
    r = sign_receipt({"schema": SCHEMA, "scans": [], "pricebook": {}, "n": 1})
    r["n"] = 2  # tamper the body after signing
    res = verify_primitive(r, rehash_inputs=False)
    assert res.ok is False
    assert "receipt-signature-invalid" in res.problems
    # Primitive never diverges from the deterministic op it wraps.
    assert res.problems == verify_receipt(r, rehash_inputs=False)


def test_verify_primitive_registered_as_read_only_tool():
    p = REGISTRY["verify"]
    assert p.permission == Permission.READ           # safe for read-only sessions
    assert p.input_schema and p.output_schema        # minimal contract present
    assert set(p.output_schema) == {
        "ok", "problems", "provenance", "rule_version", "timestamp"}
    assert "verify" in list_primitives(Permission.READ)


def test_verify_primitive_total_on_signed_malformed_path():
    # A SIGNED receipt whose scan entry lacks 'path' must NOT raise — the core
    # emits a named reason and the primitive returns the full contract shape.
    r = sign_receipt({"schema": SCHEMA, "scans": [{"sha256": "deadbeef"}], "pricebook": {}})
    res = verify_primitive(r, rehash_inputs=True)          # must not raise
    assert isinstance(res, VerificationResult)
    assert res.ok is False
    assert "scan-malformed-no-path" in res.problems
    assert res.problems == verify_receipt(r, rehash_inputs=True)


def test_verify_primitive_provenance_honest_on_failure_paths():
    # Unsigned → no signature check ran → signatureChecked False (no theater).
    unsigned = {"schema": SCHEMA, "scans": [], "pricebook": {}}
    pv = verify_primitive(unsigned, rehash_inputs=True).provenance
    assert pv["signatureChecked"] is False
    # Signed but referenced files absent → they were NEVER hashed, so provenance
    # must not list them.
    r = sign_receipt({
        "schema": SCHEMA,
        "scans": [{"path": "/no/such/scan.png", "sha256": "x", "file": "scan.png"}],
        "pricebook": {"path": "/no/such/pb.csv", "sha256": "y"},
    })
    res = verify_primitive(r, rehash_inputs=True)
    assert res.ok is False
    assert any("absent" in p for p in res.problems)
    assert res.provenance["signatureChecked"] is True      # a real signature WAS checked
    assert res.provenance["reHashed"]["scans"] == []        # absent → not hashed → not claimed
    assert res.provenance["reHashed"]["pricebook"] is None


def test_verify_primitive_provenance_pins_every_rehashed_surface():
    # Multi-site discipline: assert ALL six hashed-input provenance surfaces by
    # name, against a receipt that configures every one of them.
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d, _kist_fixture({
        "HYD-4410|HYDRAULIC PUMP ASSY": _PUMP,
        "FLT-2200|FORKLIFT BRAKE KIT": {"unit_price_usd": 400.0},
        "SEN-7781|PROXIMITY SENSOR HD": {"unit_price_usd": 60.0},
    }):
        scans = Path(d) / "scans"
        shutil.copytree(DEMO / "scans", scans)
        base = audit_folder(scans, DEMO / "pricebook.csv")
        bench = refresh_all(items_from_receipt(base), Path(d) / "bench", mode="dig")
        receipt = audit_folder(scans, DEMO / "pricebook.csv",
                               floor_path=DEMO / "floor-rules.json",
                               market_path=bench.market_csv,
                               market_benchmarks_path=bench.sidecar)
        rh = verify_primitive(receipt, rehash_inputs=True).provenance["reHashed"]
        assert rh["scans"] == [s["path"] for s in receipt["scans"]]
        assert rh["sources"] == [s["source_path"] for s in receipt["scans"]]
        assert rh["pricebook"] == receipt["pricebook"]["path"]
        assert rh["marketPricebook"] == receipt["marketPricebook"]["path"]
        assert rh["marketBenchmarks"] == receipt["marketBenchmarks"]["path"]
        assert rh["floorRules"] == receipt["floorRules"]["path"]


def test_verify_result_authoritative_part_stable_across_runs():
    # Stability invariant: same inputs + same rules => identical authoritative
    # result; only the timestamp (metadata) may drift.
    r = sign_receipt({"schema": SCHEMA, "scans": [], "pricebook": {}, "n": 7})
    a = verify_primitive(r, rehash_inputs=False).to_dict()
    b = verify_primitive(r, rehash_inputs=False).to_dict()
    del a["timestamp"]
    del b["timestamp"]
    assert a == b


# ---------------------------------------------------------------------------
# Provenance honesty — reHashed must reflect ONLY files whose bytes were read.
# Codex r-gate 2026-08-21 found three ways it could over-claim. One pin per hole.
# ---------------------------------------------------------------------------

def test_provenance_unsigned_never_claims_rehash():
    # HOLE 1: an unsigned receipt short-circuits before ANY hashing. Provenance
    # must not claim a re-hash the core never performed — even with a real,
    # present file on disk and rehash ON.
    with tempfile.TemporaryDirectory() as d:
        scan = Path(d) / "real.png"
        scan.write_bytes(b"pixels")
        digest = hashlib.sha256(scan.read_bytes()).hexdigest()
        unsigned = {  # deliberately no signature/publicKey
            "schema": SCHEMA,
            "scans": [{"path": str(scan), "sha256": digest, "file": "real.png"}],
            "pricebook": {},
        }
        res = verify_primitive(unsigned, rehash_inputs=True)
        assert "receipt-unsigned" in res.problems
        assert res.provenance["signatureChecked"] is False
        assert res.provenance["reHashed"]["scans"] == []   # nothing was hashed
        assert res.problems == verify_receipt(unsigned, rehash_inputs=True)


def test_provenance_source_without_sha_not_claimed():
    # HOLE 2: a scan with source_path but NO source_sha256 is not re-hashed by
    # the core (it needs both). Provenance must not list the source as hashed.
    with tempfile.TemporaryDirectory() as d:
        scan = Path(d) / "scan.png"
        src = Path(d) / "orig.pdf"
        scan.write_bytes(b"img")
        src.write_bytes(b"pdf-bytes")
        r = sign_receipt({
            "schema": SCHEMA,
            "scans": [{
                "path": str(scan),
                "sha256": hashlib.sha256(scan.read_bytes()).hexdigest(),
                "file": "scan.png",
                "source_path": str(src),      # present on disk...
                # ...but NO source_sha256 → the core never hashes it.
            }],
            "pricebook": {},
        })
        res = verify_primitive(r, rehash_inputs=True)
        assert res.provenance["reHashed"]["scans"] == [str(scan)]  # scan WAS hashed
        assert res.provenance["reHashed"]["sources"] == []          # source was NOT
        assert res.problems == verify_receipt(r, rehash_inputs=True)


def test_provenance_dup_basename_absent_does_not_hide_hashed_sibling():
    # HOLE 3: two scans sharing a basename in different dirs, one absent, one
    # present. Basename-keyed reason matching used to drop the present (hashed)
    # file from provenance. Now reHashed is recorded by actual full path.
    with tempfile.TemporaryDirectory() as d:
        present = Path(d) / "a" / "invoice.png"
        absent = Path(d) / "b" / "invoice.png"     # same basename, never created
        present.parent.mkdir(parents=True)
        present.write_bytes(b"real")
        r = sign_receipt({
            "schema": SCHEMA,
            "scans": [
                {"path": str(present), "sha256": hashlib.sha256(b"real").hexdigest(),
                 "file": "invoice.png"},
                {"path": str(absent), "sha256": "deadbeef", "file": "invoice.png"},
            ],
            "pricebook": {},
        })
        res = verify_primitive(r, rehash_inputs=True)
        assert str(present) in res.provenance["reHashed"]["scans"]   # not hidden
        assert str(absent) not in res.provenance["reHashed"]["scans"]
        assert any("scan-absent:invoice.png" == p for p in res.problems)
        assert res.problems == verify_receipt(r, rehash_inputs=True)


# ---------------------------------------------------------------------------
# EXPECTED invariants — the self-healing keystone. `verify` re-proves the audit's
# own verdicts from the receipt's numbers, so a re-signed tamper is caught even
# though the forged signature is valid. Multi-site: one pin PER invariant kind.
# ---------------------------------------------------------------------------

def _resign(receipt, mutate):
    """Return a freshly-signed receipt after applying `mutate(body)` — simulates
    an attacker who edits the body and forges a NEW valid signature."""
    body = {k: v for k, v in receipt.items() if k not in ("signature", "publicKey")}
    mutate(body)
    return sign_receipt(body)


def _demo_receipt():
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        scans = Path(d) / "scans"
        shutil.copytree(DEMO / "scans", scans)
        return audit_folder(scans, DEMO / "pricebook.csv",
                            floor_path=DEMO / "floor-rules.json")


def test_audit_emits_expected_invariants_and_they_all_hold():
    r = _demo_receipt()
    assert r["schema"] == "perslis.invoice-audit-receipt.v3"
    assert r["expectedVersion"] == INVARIANTS_VERSION
    kinds = {e["kind"] for e in r["expected"]}
    assert kinds == {"line-arithmetic", "invoice-reconcile", "floor-max-unit-price"}
    # A freshly-audited receipt's own invariants must all hold (self-consistent).
    assert check_invariants(r) == []
    assert verify_receipt(r, rehash_inputs=False) == []


def test_invariant_line_arithmetic_catches_resigned_tamper():
    r = _demo_receipt()
    def bump(body):
        body["invoices"][0]["lines"][0]["line_total"] = round(
            body["invoices"][0]["lines"][0]["line_total"] + 500.0, 2)
    forged = _resign(r, bump)
    probs = verify_receipt(forged, rehash_inputs=False)
    assert "receipt-signature-invalid" not in probs      # forged sig is VALID
    assert any(p.startswith("invariant-violated:line-arithmetic:") for p in probs)


def test_invariant_invoice_reconcile_catches_resigned_tamper():
    r = _demo_receipt()
    target = r["invoices"][0]["file"]
    def flip(body):
        for inv in body["invoices"]:
            if inv["file"] == target:
                inv["statedTotalReconciles"] = not inv["statedTotalReconciles"]
    forged = _resign(r, flip)
    probs = verify_receipt(forged, rehash_inputs=False)
    assert "receipt-signature-invalid" not in probs
    assert f"invariant-violated:invoice-reconcile:{target}" in probs


def test_invariant_floor_max_catches_suppressed_veto():
    # The floor invariant pins: unit_price exceeds the taught max IFF a floor-veto
    # is recorded. Suppress the veto flag (keep the over-max price) -> violation.
    r = _demo_receipt()
    decl = next(e for e in r["expected"] if e["kind"] == "floor-max-unit-price")
    vetoed_file = decl["scope"]["invoice"]
    def suppress(body):
        for inv in body["invoices"]:
            if inv["file"] == vetoed_file:
                inv["flags"] = [f for f in inv["flags"] if f.get("kind") != "floor-veto"]
    forged = _resign(r, suppress)
    probs = verify_receipt(forged, rehash_inputs=False)
    assert "receipt-signature-invalid" not in probs
    assert f"invariant-violated:{decl['id']}" in probs


def test_invariant_unresolvable_when_declaration_references_missing_invoice():
    # A declaration pointing at an invoice the body no longer contains must fail
    # closed (never silently pass, never crash).
    r = sign_receipt({
        "schema": SCHEMA, "scans": [], "pricebook": {},
        "invoices": [],
        "expected": [{"id": "line-arithmetic:ghost.png:0", "kind": "line-arithmetic",
                      "scope": {"invoice": "ghost.png", "line": 0},
                      "statement": "..."}],
        "expectedVersion": INVARIANTS_VERSION,
    })
    probs = verify_receipt(r, rehash_inputs=False)
    assert "invariant-unresolvable:line-arithmetic:ghost.png:0" in probs


def test_check_invariants_never_raises_on_hostile_expected():
    # Malformed declarations / non-dict receipt fail closed, never traceback.
    assert check_invariants("not-a-dict") == ["invariant-unresolvable:receipt-not-a-dict"]
    r = {"expected": ["not-a-dict", {"kind": "unknown-kind", "scope": {}, "id": "x"}],
         "invoices": []}
    probs = check_invariants(r)
    assert "invariant-unresolvable:malformed-declaration" in probs
    # unknown kind with an unresolvable invoice ref -> unresolvable, no crash.
    assert any(p.startswith("invariant-unresolvable") for p in probs)


def test_older_schema_without_expected_is_backward_compat():
    # An older (pre-invariants) schema without an `expected` block still passes —
    # the invariant layer is additive, never a new way to fail a valid old receipt.
    old = {"schema": "perslis.invoice-audit-receipt.v2",
           "invoices": [{"file": "x.png", "lines": [], "statedTotalReconciles": False}]}
    assert check_invariants(old) == []


def test_contentless_current_receipt_needs_no_invariants():
    # A current-schema receipt with no audited invoices has nothing to prove.
    r = sign_receipt({"schema": SCHEMA, "scans": [], "pricebook": {}})
    assert check_invariants(r) == []
    assert verify_receipt(r, rehash_inputs=False) == []


def test_stripped_expected_block_fails_closed_not_bypassed():
    # HIGH (Codex r-gate): a CURRENT-schema receipt WITH invoices but a stripped
    # `expected` block must fail closed — invariants are not attacker-optional.
    with_content = {"schema": SCHEMA, "expectedVersion": INVARIANTS_VERSION,
                    "invoices": [{"file": "a.png",
                                  "lines": [{"qty": 1, "unit_price": 5.0, "line_total": 5.0}],
                                  "statedTotalReconciles": False}]}
    # expected entirely absent
    assert "invariant-missing:expected-block-absent" in check_invariants(with_content)
    # expected emptied to [] while invoices remain -> per-surface missing
    emptied = {**with_content, "expected": []}
    probs = check_invariants(emptied)
    assert "invariant-missing:invoice-reconcile:a.png" in probs
    assert "invariant-missing:line-arithmetic:a.png:0" in probs
    # a single line's arithmetic invariant stripped -> that exact surface named
    partial = {**with_content, "expected": [
        {"id": "invoice-reconcile:a.png", "kind": "invoice-reconcile",
         "scope": {"invoice": "a.png"}}]}
    assert "invariant-missing:line-arithmetic:a.png:0" in check_invariants(partial)


def test_floor_invariant_covers_passing_line_not_just_vetoed():
    # HIGH (Codex r-gate): a line UNDER a taught max that PASSES must still carry a
    # floor invariant, so it cannot be re-signed into an over-max line unnoticed.
    # A generous "*" max means every line is covered AND passes.
    _ensure_fixtures()
    with tempfile.TemporaryDirectory() as d:
        scans = Path(d) / "scans"
        shutil.copytree(DEMO / "scans", scans)
        floor = Path(d) / "floor.json"
        floor.write_text(json.dumps({
            "schema": "invoice-audit.floor.v1",
            "rules": [{"subject": "*", "relation_type": "max_unit_price",
                       "object": "1000000.00", "source": "test",
                       "evidence": "generous cap so every line passes"}]}))
        r = audit_folder(scans, DEMO / "pricebook.csv", floor_path=floor)
        passing = None
        for inv in r["invoices"]:
            for i, line in enumerate(inv["lines"]):
                amp = (line.get("floor") or {}).get("appliedMaxUnitPrice")
                vetoed = any(f.get("kind") == "floor-veto" and f.get("line") == i
                             for f in inv["flags"])
                if amp and not vetoed:
                    passing = (inv["file"], i, amp["object"])
        assert passing, "expected a passing line under the generous taught max"
        file, idx, cap = passing
        # That passing line must have a floor invariant declared.
        assert any(e["kind"] == "floor-max-unit-price"
                   and e["scope"] == {"invoice": file, "line": idx}
                   for e in r["expected"])
        # Re-sign it over the cap without adding a veto -> invariant catches it.
        def over(body):
            for inv in body["invoices"]:
                if inv["file"] == file:
                    inv["lines"][idx]["unit_price"] = round(cap + 10.0, 2)
                    # keep arithmetic self-consistent so ONLY the floor invariant fires
                    inv["lines"][idx]["line_total"] = round(
                        inv["lines"][idx]["qty"] * (cap + 10.0), 2)
        forged = _resign(r, over)
        probs = verify_receipt(forged, rehash_inputs=False)
        assert "receipt-signature-invalid" not in probs
        assert f"invariant-violated:floor-max-unit-price:{file}:{idx}" in probs


def test_invoice_reconcile_nonbool_recorded_fails_closed():
    # MEDIUM (Codex r-gate): a missing/malformed statedTotalReconciles must fail
    # closed to unresolvable, not let bool(None)==False silently pass.
    r = {"schema": "perslis.invoice-audit-receipt.v2",
         "invoices": [{"file": "a.png", "lines": [], "stated_total": None}],  # no reconcile key
         "expected": [{"id": "invoice-reconcile:a.png", "kind": "invoice-reconcile",
                       "scope": {"invoice": "a.png"}}]}
    assert "invariant-unresolvable:invoice-reconcile:a.png" in check_invariants(r)


def test_check_invariants_total_on_hostile_container_shapes():
    # MEDIUM (Codex r-gate): None invoices / non-dict scope / non-list flags must
    # never raise — fail closed to named reasons.
    assert check_invariants({"expected": [], "invoices": None}) == []
    r = {"schema": "perslis.invoice-audit-receipt.v2",
         "invoices": [{"file": "a.png",
                       "lines": [{"qty": 1, "unit_price": 5.0, "line_total": 5.0}],
                       "flags": "not-a-list", "statedTotalReconciles": True,
                       "stated_total": 5.0}],
         "expected": [
             {"id": "s", "kind": "line-arithmetic", "scope": "not-a-dict"},
             {"id": "line-arithmetic:a.png:0", "kind": "line-arithmetic",
              "scope": {"invoice": "a.png", "line": 0}},
         ]}
    probs = check_invariants(r)                                   # must not raise
    assert "invariant-unresolvable:s" in probs                    # non-dict scope


def test_stripped_invoices_but_kept_totals_still_requires_invariants():
    # HIGH (Codex r-gate 2): stripping `invoices` while keeping `totals` that
    # still CLAIM findings must not dodge the invariant requirement.
    forged = {"schema": SCHEMA,
              "totals": {"invoices": 3, "linesChecked": 7, "flagged": 2}}
    assert "invariant-missing:expected-block-absent" in check_invariants(forged)
    # But a genuinely vacuous current-schema receipt claims nothing -> nothing due.
    assert check_invariants({"schema": SCHEMA}) == []
    assert check_invariants({"schema": SCHEMA, "totals": {"linesChecked": 0}}) == []


def test_stripped_floor_declaration_named_missing():
    # HIGH (Codex r-gate 2): a line under a taught max whose floor-max declaration
    # was removed must be named missing, not silently uncovered.
    line = {"qty": 1, "unit_price": 50.0, "line_total": 50.0,
            "floor": {"appliedMaxUnitPrice": {"object": 60.0, "source": "ops"}}}
    r = {"schema": SCHEMA, "expectedVersion": INVARIANTS_VERSION,
         "invoices": [{"file": "a.png", "lines": [line], "statedTotalReconciles": False}],
         "expected": [
             {"id": "line-arithmetic:a.png:0", "kind": "line-arithmetic",
              "scope": {"invoice": "a.png", "line": 0}},
             {"id": "invoice-reconcile:a.png", "kind": "invoice-reconcile",
              "scope": {"invoice": "a.png"}},
             # floor-max-unit-price deliberately omitted
         ]}
    assert "invariant-missing:floor-max-unit-price:a.png:0" in check_invariants(r)


def test_floor_invariant_matches_max_veto_only_not_other_relations():
    # MEDIUM (Codex r-gate 2): a floor-veto for a DIFFERENT relation (qty_integer)
    # must not be read as the max veto.
    covered = {"qty": 1, "unit_price": 50.0, "line_total": 50.0,   # 50 <= 60: passes max
               "floor": {"appliedMaxUnitPrice": {"object": 60.0, "source": "ops"}}}
    decl = [{"id": "floor-max-unit-price:a.png:0", "kind": "floor-max-unit-price",
             "scope": {"invoice": "a.png", "line": 0}, "bound": 60.0}]
    # v2 schema so coverage strictness doesn't demand the other declarations.
    holds = {"schema": "perslis.invoice-audit-receipt.v2",
             "invoices": [{"file": "a.png", "lines": [covered],
                           "statedTotalReconciles": False,
                           "flags": [{"kind": "floor-veto", "line": 0,
                                      "relation_type": "qty_integer"}]}],
             "expected": decl}
    assert not any("floor-max" in p for p in check_invariants(holds))   # not falsely flagged
    # Over the max, but only a qty veto remains (max veto suppressed) -> violated.
    over = dict(covered, unit_price=100.0, line_total=100.0)
    forged = {"schema": "perslis.invoice-audit-receipt.v2",
              "invoices": [{"file": "a.png", "lines": [over],
                            "statedTotalReconciles": False,
                            "flags": [{"kind": "floor-veto", "line": 0,
                                       "relation_type": "qty_integer"}]}],
              "expected": decl}
    assert "invariant-violated:floor-max-unit-price:a.png:0" in check_invariants(forged)


def test_flag_bool_line_index_not_counted_as_line_zero():
    # MEDIUM (Codex r-gate 2): {"line": False} must NOT satisfy line 0's recorded
    # verdict (False == 0 in Python). Line 0 is genuinely mis-arithmetic'd here,
    # so with the bogus flag ignored the invariant is violated (no real flag).
    line = {"qty": 2.0, "unit_price": 3.0, "line_total": 5.0}      # 6 != 5
    r = {"schema": "perslis.invoice-audit-receipt.v2",
         "invoices": [{"file": "a.png", "lines": [line],
                       "statedTotalReconciles": False,
                       "flags": [{"kind": "arithmetic-mismatch", "line": False}]}],
         "expected": [{"id": "line-arithmetic:a.png:0", "kind": "line-arithmetic",
                       "scope": {"invoice": "a.png", "line": 0}}]}
    assert "invariant-violated:line-arithmetic:a.png:0" in check_invariants(r)


def test_verify_primitive_provenance_reports_invariants_held():
    r = _demo_receipt()
    res = verify_primitive(r, rehash_inputs=False)
    n = len(r["expected"])
    iv = res.provenance["invariants"]
    assert iv["declared"] == n
    assert iv["checked"] is True and iv["held"] is True      # signed + all hold
    assert iv["version"] == INVARIANTS_VERSION
    # Unsigned short-circuits before invariants -> not checked, not held (honest).
    unsigned = {k: v for k, v in r.items() if k not in ("signature", "publicKey")}
    pv = verify_primitive(unsigned, rehash_inputs=False).provenance["invariants"]
    assert pv["declared"] == n and pv["checked"] is False and pv["held"] is False
    # A re-signed tampered receipt is checked but does NOT hold — no overclaim.
    forged = _resign(r, lambda b: b["invoices"][0]["lines"][0].__setitem__(
        "line_total", round(b["invoices"][0]["lines"][0]["line_total"] + 9, 2)))
    fv = verify_primitive(forged, rehash_inputs=False).provenance["invariants"]
    assert fv["checked"] is True and fv["held"] is False


def test_money_totals_alone_claim_content_and_demand_invariants():
    # HIGH (Codex r-gate 3): a forgery keeping only a money total (not the count
    # keys) while stripping invoices/expected must still be required to prove.
    forged = {"schema": SCHEMA, "totals": {"potentialOverchargeUSD": 6000.0}}
    assert "invariant-missing:expected-block-absent" in check_invariants(forged)


def test_stripped_invoices_with_empty_expected_and_totals_fails_closed():
    # HIGH (Codex r-gate 3): invoices stripped, expected emptied to [], but totals
    # still claim content -> the invoices-stripped guard catches it.
    forged = {"schema": SCHEMA, "expectedVersion": INVARIANTS_VERSION,
              "expected": [], "totals": {"linesChecked": 7}}
    assert "invariant-missing:invoices-stripped" in check_invariants(forged)


def test_floor_forged_high_bound_does_not_beat_line_cap():
    # HIGH (Codex r-gate 3): a forged high `bound` in the signed declaration must
    # not be trusted over the line's own recorded cap. Cross-check catches it.
    over = {"qty": 1, "unit_price": 100.0, "line_total": 100.0,
            "floor": {"appliedMaxUnitPrice": {"object": 60.0, "source": "ops"}}}
    r = {"schema": "perslis.invoice-audit-receipt.v2",
         "invoices": [{"file": "a.png", "lines": [over],
                       "statedTotalReconciles": False, "flags": []}],
         "expected": [{"id": "floor-max-unit-price:a.png:0",
                       "kind": "floor-max-unit-price",
                       "scope": {"invoice": "a.png", "line": 0},
                       "bound": 999999.0}]}   # forged high cap
    assert "invariant-violated:floor-max-unit-price:a.png:0" in check_invariants(r)


def test_unknown_invariants_version_fails_closed():
    # MEDIUM (Codex r-gate 3): a current-schema content receipt declaring an
    # invariants version we don't know how to check must fail closed.
    r = {"schema": SCHEMA, "expectedVersion": "invoice-audit.invariants.v999",
         "invoices": [{"file": "a.png", "lines": [], "statedTotalReconciles": False}],
         "expected": []}
    probs = check_invariants(r)
    assert any(p.startswith("invariant-unresolvable:expected-version") for p in probs)


def test_unhashable_scope_value_fails_closed_not_crash():
    # MEDIUM (Codex r-gate 3): a hostile unhashable scope value must not crash the
    # coverage set-build; it fails closed via the per-declaration loop.
    r = {"schema": "perslis.invoice-audit-receipt.v2",
         "invoices": [{"file": "a.png", "lines": [], "statedTotalReconciles": False}],
         "expected": [{"id": "x", "kind": "line-arithmetic",
                       "scope": {"invoice": {"nested": "dict"}, "line": 0}}]}
    probs = check_invariants(r)                          # must not raise
    assert "invariant-unresolvable:x" in probs


def test_floor_veto_detail_fallback_when_relation_type_absent():
    # MEDIUM (Codex r-gate 3): a pre-fix floor-veto flag with no structured
    # relation_type is matched via the detail string (backward-compat).
    over = {"qty": 1, "unit_price": 100.0, "line_total": 100.0,
            "floor": {"appliedMaxUnitPrice": {"object": 60.0, "source": "ops"}}}
    r = {"schema": "perslis.invoice-audit-receipt.v2",
         "invoices": [{"file": "a.png", "lines": [over],
                       "statedTotalReconciles": False,
                       "flags": [{"kind": "floor-veto", "line": 0,
                                  "detail": "unit 100 exceeds taught max 60 "
                                            "[max_unit_price src=ops]"}]}],
         "expected": [{"id": "floor-max-unit-price:a.png:0",
                       "kind": "floor-max-unit-price",
                       "scope": {"invoice": "a.png", "line": 0}, "bound": 60.0}]}
    # exceeds (100>60) True and the veto is matched via detail -> holds, no flag.
    assert not any("floor-max" in p for p in check_invariants(r))


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
        passed += 1
    print(f"\n{passed}/{len(fns)} passed")
