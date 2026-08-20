"""SQLite persistence for the business-analysis backend.

Receipts are still the signed proof artifact. This module turns a receipt into
queryable tables: source files, invoices, line items, findings, and traceable
business claims that can later be mirrored into Jeeves/PREL.
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Iterable

from .categories import classify_invoice, classify_item

SCHEMA_VERSION = 2


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    init_db(con)
    return con


def init_db(con: sqlite3.Connection) -> None:
    con.executescript(
        """
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS receipts (
            id INTEGER PRIMARY KEY,
            schema TEXT NOT NULL,
            generated_at TEXT NOT NULL,
            signature TEXT NOT NULL UNIQUE,
            public_key TEXT NOT NULL,
            receipt_json TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS source_files (
            id INTEGER PRIMARY KEY,
            receipt_id INTEGER NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            rows INTEGER,
            UNIQUE(receipt_id, kind, path)
        );

        CREATE TABLE IF NOT EXISTS invoices (
            id INTEGER PRIMARY KEY,
            receipt_id INTEGER NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
            source_file_id INTEGER REFERENCES source_files(id) ON DELETE SET NULL,
            file_name TEXT NOT NULL,
            path TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            vendor TEXT NOT NULL,
            invoice_no TEXT NOT NULL,
            invoice_date TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT 'Uncategorized',
            stated_total REAL,
            stated_total_reconciles INTEGER NOT NULL,
            disposition TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS invoice_lines (
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
            category TEXT NOT NULL DEFAULT 'Uncategorized',
            price_verdict TEXT NOT NULL,
            grounding_verdict TEXT NOT NULL,
            floor_verdict TEXT NOT NULL,
            matched_on TEXT,
            reference_median REAL,
            delta_total REAL NOT NULL,
            policy_delta_total REAL NOT NULL DEFAULT 0,
            trace_json TEXT NOT NULL,
            UNIQUE(invoice_id, line_index)
        );

        CREATE TABLE IF NOT EXISTS findings (
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

        CREATE TABLE IF NOT EXISTS business_claims (
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

        CREATE INDEX IF NOT EXISTS idx_findings_kind ON findings(kind);
        CREATE INDEX IF NOT EXISTS idx_findings_status ON findings(status);
        CREATE INDEX IF NOT EXISTS idx_invoice_lines_sku ON invoice_lines(sku);
        CREATE INDEX IF NOT EXISTS idx_claims_relation ON business_claims(relation);
        """
    )
    _ensure_column(con, "invoices", "category", "category TEXT NOT NULL DEFAULT 'Uncategorized'")
    _ensure_column(con, "invoice_lines", "category", "category TEXT NOT NULL DEFAULT 'Uncategorized'")
    _ensure_column(con, "invoice_lines", "policy_delta_total", "policy_delta_total REAL NOT NULL DEFAULT 0")
    con.execute("CREATE INDEX IF NOT EXISTS idx_invoice_lines_category ON invoice_lines(category)")
    con.execute("CREATE INDEX IF NOT EXISTS idx_invoices_category ON invoices(category)")
    con.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)",
        (str(SCHEMA_VERSION),),
    )
    con.commit()


def store_receipt(con: sqlite3.Connection, receipt: dict) -> int:
    """Persist one signed receipt and derived query tables.

    Existing rows for the same signature are replaced so re-importing the same
    receipt is idempotent.
    """
    signature = str(receipt["signature"])
    old = con.execute(
        "SELECT id FROM receipts WHERE signature = ?", (signature,)
    ).fetchone()
    if old:
        con.execute("DELETE FROM receipts WHERE id = ?", (old["id"],))

    cur = con.execute(
        """
        INSERT INTO receipts(schema, generated_at, signature, public_key, receipt_json)
        VALUES (?, ?, ?, ?, ?)
        """,
        (
            receipt.get("schema", ""),
            receipt.get("generatedAt", ""),
            signature,
            receipt.get("publicKey", ""),
            json.dumps(receipt, sort_keys=True),
        ),
    )
    receipt_id = int(cur.lastrowid)

    source_ids = _store_sources(con, receipt_id, receipt)
    invoice_ids: dict[str, int] = {}
    line_ids: dict[tuple[str, int], int] = {}

    for inv in receipt.get("invoices", []):
        file_name = inv.get("file", "")
        source_file_id = source_ids.get(("scan", inv.get("path", "")))
        invoice_category = (inv.get("category") or
                            classify_invoice(inv.get("vendor", ""), inv.get("lines", [])).get("category"))
        cur = con.execute(
            """
            INSERT INTO invoices(
                receipt_id, source_file_id, file_name, path, sha256, vendor,
                invoice_no, invoice_date, category, stated_total, stated_total_reconciles,
                disposition
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                receipt_id,
                source_file_id,
                file_name,
                inv.get("path", ""),
                inv.get("sha256", ""),
                inv.get("vendor", ""),
                inv.get("invoice_no", ""),
                inv.get("date", ""),
                invoice_category,
                inv.get("stated_total"),
                1 if inv.get("statedTotalReconciles") else 0,
                inv.get("disposition", ""),
            ),
        )
        invoice_id = int(cur.lastrowid)
        invoice_ids[file_name] = invoice_id
        _store_invoice_claim(con, receipt_id, inv, invoice_category)

        for idx, line in enumerate(inv.get("lines", [])):
            grounding = line.get("grounding", {}) or {}
            floor = line.get("floor", {}) or {}
            category = line.get("category") or classify_item(
                line.get("sku", ""),
                line.get("description", ""),
                inv.get("vendor", ""),
            )["category"]
            cur = con.execute(
                """
                INSERT INTO invoice_lines(
                    invoice_id, line_index, sku, description, qty, unit_price,
                    line_total, ocr_row_text, ocr_min_confidence, category, price_verdict,
                    grounding_verdict, floor_verdict, matched_on,
                    reference_median, delta_total, policy_delta_total, trace_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    invoice_id,
                    idx,
                    line.get("sku", ""),
                    line.get("description", ""),
                    float(line.get("qty", 0)),
                    float(line.get("unit_price", 0)),
                    float(line.get("line_total", 0)),
                    line.get("ocr_row_text", ""),
                    float(line.get("ocr_min_confidence", 0)),
                    category,
                    line.get("verdict", "unknown"),
                    grounding.get("verdict", "unknown"),
                    floor.get("verdict", "unknown"),
                    line.get("matched_on"),
                    line.get("reference_median"),
                    float(line.get("delta_total", 0)),
                    float(line.get("policy_delta_total", 0)),
                    json.dumps({
                        "category": category,
                        "categoryEvidence": line.get("categoryEvidence", {}),
                        "grounding": grounding,
                        "floor": floor,
                        "policy_delta_total": line.get("policy_delta_total", 0),
                        "ocr_row_text": line.get("ocr_row_text", ""),
                    }, sort_keys=True),
                ),
            )
            line_id = int(cur.lastrowid)
            line_ids[(file_name, idx)] = line_id
            _store_line_claims(con, receipt_id, inv, idx, line)

    for item in receipt.get("reviewQueue", []):
        invoice_file = item.get("invoice", "")
        line_index = item.get("line")
        invoice_id = invoice_ids.get(invoice_file)
        line_id = (
            line_ids.get((invoice_file, int(line_index)))
            if isinstance(line_index, int)
            else None
        )
        con.execute(
            """
            INSERT INTO findings(
                receipt_id, invoice_id, line_id, kind, severity, detail, evidence_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                receipt_id,
                invoice_id,
                line_id,
                item.get("kind", ""),
                item.get("severity") or severity_for(item.get("kind", "")),
                item.get("detail", ""),
                json.dumps(item, sort_keys=True),
            ),
        )

    con.commit()
    return receipt_id


def _ensure_column(
    con: sqlite3.Connection,
    table: str,
    column: str,
    column_sql: str,
) -> None:
    existing = {
        row["name"]
        for row in con.execute(f"PRAGMA table_info({table})").fetchall()
    }
    if column not in existing:
        con.execute(f"ALTER TABLE {table} ADD COLUMN {column_sql}")


def _store_sources(con: sqlite3.Connection, receipt_id: int, receipt: dict) -> dict[tuple[str, str], int]:
    source_ids: dict[tuple[str, str], int] = {}
    for scan in receipt.get("scans", []):
        source_ids[("scan", scan.get("path", ""))] = _insert_source(
            con,
            receipt_id,
            "scan",
            scan.get("path", ""),
            scan.get("file", Path(scan.get("path", "")).name),
            scan.get("sha256", ""),
            None,
        )
        source_path = scan.get("source_path")
        if source_path and source_path != scan.get("path"):
            source_ids[(scan.get("source_kind", "source"), source_path)] = _insert_source(
                con,
                receipt_id,
                scan.get("source_kind", "source"),
                source_path,
                Path(source_path).name,
                scan.get("source_sha256", ""),
                None,
            )

    pricebook = receipt.get("pricebook", {}) or {}
    if pricebook.get("path"):
        source_ids[("pricebook", pricebook.get("path", ""))] = _insert_source(
            con,
            receipt_id,
            "pricebook",
            pricebook.get("path", ""),
            Path(pricebook.get("path", "")).name,
            pricebook.get("sha256", ""),
            pricebook.get("rows"),
        )

    rules = receipt.get("floorRules", {}) or {}
    if rules.get("path"):
        source_ids[("rules", rules.get("path", ""))] = _insert_source(
            con,
            receipt_id,
            "rules",
            rules.get("path", ""),
            Path(rules.get("path", "")).name,
            rules.get("sha256", ""),
            rules.get("rules"),
        )
    return source_ids


def _insert_source(
    con: sqlite3.Connection,
    receipt_id: int,
    kind: str,
    path: str,
    file_name: str,
    sha256: str,
    rows: int | None,
) -> int:
    con.execute(
        """
        INSERT OR IGNORE INTO source_files(receipt_id, kind, path, file_name, sha256, rows)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (receipt_id, kind, path, file_name, sha256, rows),
    )
    row = con.execute(
        """
        SELECT id FROM source_files
        WHERE receipt_id = ? AND kind = ? AND path = ?
        """,
        (receipt_id, kind, path),
    ).fetchone()
    return int(row["id"])


def _store_invoice_claim(
    con: sqlite3.Connection,
    receipt_id: int,
    inv: dict,
    category: str,
) -> None:
    invoice_ref = f"invoice:{inv.get('invoice_no') or inv.get('file')}"
    evidence = {
        "invoice": inv.get("file"),
        "path": inv.get("path"),
        "sha256": inv.get("sha256"),
        "source_path": inv.get("source_path"),
        "source_sha256": inv.get("source_sha256"),
        "source_kind": inv.get("source_kind"),
        "source_page": inv.get("source_page"),
        "vendor": inv.get("vendor"),
        "categoryEvidence": inv.get("categoryEvidence", {}),
    }
    con.execute(
        """
        INSERT INTO business_claims(
            receipt_id, subject, relation, object, source_kind, source_ref,
            jeeves_verdict, prel_trace_json, evidence_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            receipt_id,
            invoice_ref,
            "invoice_category",
            category,
            "receipt",
            inv.get("file", ""),
            "consistent",
            json.dumps({
                "source": "invoice-audit",
                "document": inv.get("file"),
                "document_sha256": inv.get("sha256"),
                "categoryEvidence": inv.get("categoryEvidence", {}),
            }, sort_keys=True),
            json.dumps(evidence, sort_keys=True),
        ),
    )


def _store_line_claims(
    con: sqlite3.Connection,
    receipt_id: int,
    inv: dict,
    line_index: int,
    line: dict,
) -> None:
    invoice_ref = f"invoice:{inv.get('invoice_no') or inv.get('file')}:line:{line_index + 1}"
    base_evidence = {
        "invoice": inv.get("file"),
        "path": inv.get("path"),
        "sha256": inv.get("sha256"),
        "source_path": inv.get("source_path"),
        "source_sha256": inv.get("source_sha256"),
        "source_kind": inv.get("source_kind"),
        "source_page": inv.get("source_page"),
        "line_index": line_index,
        "ocr_row_text": line.get("ocr_row_text", ""),
        "grounding": line.get("grounding", {}),
    }
    claims = [
        (invoice_ref, "has_sku", line.get("sku", "")),
        (invoice_ref, "has_description", line.get("description", "")),
        (invoice_ref, "has_qty", str(line.get("qty", ""))),
        (invoice_ref, "has_unit_price", str(line.get("unit_price", ""))),
        (invoice_ref, "has_line_total", str(line.get("line_total", ""))),
        (invoice_ref, "belongs_to_category", line.get("category") or classify_item(
            line.get("sku", ""),
            line.get("description", ""),
            inv.get("vendor", ""),
        )["category"]),
        (invoice_ref, "price_verdict", line.get("verdict", "unknown")),
        (invoice_ref, "grounding_verdict", (line.get("grounding", {}) or {}).get("verdict", "unknown")),
        (invoice_ref, "floor_verdict", (line.get("floor", {}) or {}).get("verdict", "unknown")),
    ]
    for subject, relation, obj in claims:
        con.execute(
            """
            INSERT INTO business_claims(
                receipt_id, subject, relation, object, source_kind, source_ref,
                jeeves_verdict, prel_trace_json, evidence_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                receipt_id,
                subject,
                relation,
                str(obj),
                "receipt",
                inv.get("file", ""),
                _jeeves_verdict_for(line, relation),
                json.dumps(_prel_trace(inv, line_index, line), sort_keys=True),
                json.dumps(base_evidence, sort_keys=True),
            ),
        )


def _prel_trace(inv: dict, line_index: int, line: dict) -> dict:
    return {
        "source": "invoice-audit",
        "document": inv.get("file"),
        "document_sha256": inv.get("sha256"),
        "line_index": line_index,
        "ocr_row_text": line.get("ocr_row_text", ""),
        "category": line.get("category", ""),
        "categoryEvidence": line.get("categoryEvidence", {}),
        "policy_delta_total": line.get("policy_delta_total", 0),
        "numbers": (line.get("grounding", {}) or {}).get("numbers", {}),
        "witnesses": (line.get("grounding", {}) or {}).get("witnesses", []),
    }


def _jeeves_verdict_for(line: dict, relation: str) -> str:
    if relation == "floor_verdict" and (line.get("floor", {}) or {}).get("veto"):
        return "contradiction"
    if relation == "grounding_verdict":
        verdict = (line.get("grounding", {}) or {}).get("verdict")
        if verdict == "grounded":
            return "consistent"
        if verdict == "ungrounded":
            return "contradiction"
        return "unknown"
    if relation == "price_verdict" and line.get("verdict") == "overcharge-flag":
        return "contradiction"
    return "consistent"


def severity_for(kind: str) -> str:
    if kind in {"overcharge-flag", "market-overcharge-flag"}:
        return "money"
    if kind == "floor-veto":
        return "policy"
    if kind in {"arithmetic-mismatch", "weak-grounding", "ungrounded", "low-confidence"}:
        return "evidence"
    if kind.startswith("llm-") or kind in {
        "missing-or-unreadable-date", "future-dated-invoice", "duplicate-invoice-number",
    }:
        return "evidence"
    return "reference"


def list_findings(con: sqlite3.Connection, limit: int = 50) -> list[sqlite3.Row]:
    return list(con.execute(
        """
        SELECT f.id, f.kind, f.severity, f.status, f.detail,
               i.file_name AS invoice, l.line_index, l.sku, l.description,
               l.category, l.unit_price, l.line_total
        FROM findings f
        LEFT JOIN invoices i ON i.id = f.invoice_id
        LEFT JOIN invoice_lines l ON l.id = f.line_id
        WHERE f.receipt_id = (SELECT MAX(id) FROM receipts)
        ORDER BY
            CASE f.severity
                WHEN 'money' THEN 0
                WHEN 'policy' THEN 1
                WHEN 'evidence' THEN 2
                ELSE 3
            END,
            f.id
        LIMIT ?
        """,
        (limit,),
    ))


def count_rows(con: sqlite3.Connection, tables: Iterable[str]) -> dict[str, int]:
    out: dict[str, int] = {}
    for table in tables:
        out[table] = int(con.execute(f"SELECT COUNT(*) AS n FROM {table}").fetchone()["n"])
    return out
