"""Per-site pins for the invoice-audit engine. Run: python3 -m pytest tests/ -q
(or python3 tests/test_invoice_audit.py to run without pytest).

Each stage is pinned independently; the end-to-end test asserts the three
planted cases (overcharge / arithmetic / no-reference) each flag, by name.
"""
from __future__ import annotations

import json
import base64
import os
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
    # Honest: max(history, industry) + policy — never the double-counting sum.
    assert r["moneyCaughtUSD"] == 6180.0
    assert r["moneyCaughtUSD"] < 6060.0 + 2780.0 + 120.0  # provably not summed
    assert r["flagsFound"] == 4
    # "Things you'd have missed" surfaced per source.
    assert r["itemsSurfaced"]["noPriceHistory"] == 1
    assert r["itemsSurfaced"]["noIndustryBenchmark"] == 1
    assert r["itemsSurfaced"]["dataQuality"] == 1
    assert "industry" in r["headline"].lower()
    assert "6,180" in savings_text(_savings_fixture_receipt())


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


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
        passed += 1
    print(f"\n{passed}/{len(fns)} passed")
