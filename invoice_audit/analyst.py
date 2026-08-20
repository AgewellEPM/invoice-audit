"""SQL-backed business analyst answers.

This is the deterministic core under a future conversational UI: answer from
stored tables, cite source invoices/lines, and avoid inventing facts.
"""
from __future__ import annotations

import sqlite3

from .analytics import analytics_text, category_summary, overview, vendor_summary


def answer_question(con: sqlite3.Connection, question: str) -> str:
    q = question.lower()
    if any(term in q for term in ("summary", "status", "overview", "what changed")):
        return _summary(con)
    if any(term in q for term in ("category", "categories", "type", "types", "mapped")):
        return _category_answer(con)
    if any(term in q for term in ("vendor", "supplier")):
        return _vendor_answer(con)
    if any(term in q for term in ("profit", "revenue", "making the most", "make the most")):
        return _profit_gap_answer()
    if any(term in q for term in ("export", "csv", "slack", "report", "dashboard")):
        return _output_answer()
    if any(term in q for term in ("losing", "leak", "leaking", "loss", "costing us")):
        return analytics_text(con)
    if any(term in q for term in ("overcharge", "exposure", "money", "price drift")):
        return _findings_answer(con, "f.severity = 'money'", "Money exposure")
    if any(term in q for term in ("policy", "rule", "floor", "veto")):
        return _findings_answer(con, "f.severity = 'policy'", "Policy exceptions")
    if any(term in q for term in ("no reference", "missing history", "no history")):
        return _findings_answer(con, "f.kind = 'no-reference'", "Missing price history")
    if any(term in q for term in ("ocr", "evidence", "grounding", "math", "arithmetic")):
        return _findings_answer(con, "f.severity = 'evidence'", "Evidence issues")

    invoice = _invoice_named_in(con, question)
    if invoice:
        return _findings_answer(
            con,
            "i.file_name = ?",
            f"Findings for {invoice}",
            params=(invoice,),
        )

    return _findings_answer(con, "1 = 1", "Top open findings", limit=8)


def _summary(con: sqlite3.Connection) -> str:
    exposure = overview(con)
    totals = con.execute(
        """
        SELECT
            COUNT(DISTINCT i.id) AS invoices,
            COUNT(DISTINCT l.id) AS lines,
            COUNT(DISTINCT f.id) AS findings,
            COALESCE(SUM(CASE WHEN l.price_verdict = 'overcharge-flag'
                              THEN l.delta_total ELSE 0 END), 0) AS exposure
        FROM invoices i
        LEFT JOIN invoice_lines l ON l.invoice_id = i.id
        LEFT JOIN findings f ON f.invoice_id = i.id
        WHERE i.receipt_id = (SELECT MAX(id) FROM receipts)
        """
    ).fetchone()
    by_severity = con.execute(
        """
        SELECT severity, COUNT(*) AS n
        FROM findings
        WHERE receipt_id = (SELECT MAX(id) FROM receipts)
        GROUP BY severity
        ORDER BY severity
        """
    ).fetchall()
    severity_text = ", ".join(f"{r['severity']}={r['n']}" for r in by_severity)
    return (
        "Business audit summary\n"
        f"- invoices: {totals['invoices']}\n"
        f"- lines checked: {totals['lines']}\n"
        f"- open findings: {totals['findings']} ({severity_text or 'none'})\n"
        f"- potential overcharge: ${totals['exposure']:.2f}\n"
        f"- policy exposure: ${exposure['policy_exposure']:.2f}\n"
        f"- total exposure: ${exposure['total_exposure']:.2f}"
    )


def _findings_answer(
    con: sqlite3.Connection,
    where: str,
    title: str,
    *,
    params: tuple = (),
    limit: int = 6,
) -> str:
    rows = con.execute(
        f"""
        SELECT f.kind, f.severity, f.detail, i.file_name, i.path,
               l.line_index, l.sku, l.description, l.unit_price, l.line_total
        FROM findings f
        LEFT JOIN invoices i ON i.id = f.invoice_id
        LEFT JOIN invoice_lines l ON l.id = f.line_id
        WHERE f.receipt_id = (SELECT MAX(id) FROM receipts) AND {where}
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
        (*params, limit),
    ).fetchall()
    if not rows:
        return f"{title}\n- no matching findings"
    lines = [title]
    for r in rows:
        line = "invoice" if r["line_index"] is None else f"line {r['line_index'] + 1}"
        sku = "" if not r["sku"] else f" ({r['sku']})"
        lines.append(
            f"- [{r['severity']}] {r['kind']} in {r['file_name']} {line}{sku}: "
            f"{r['detail']} | source: {r['path']}"
        )
    return "\n".join(lines)


def _category_answer(con: sqlite3.Connection) -> str:
    rows = category_summary(con)
    if not rows:
        return "Invoice category map\n- no category data yet"
    lines = ["Invoice category map"]
    for row in rows:
        lines.append(
            f"- {row['category']}: {row['lines']} lines, "
            f"spend ${row['spend']:.2f}, "
            f"exposure ${row['total_exposure']:.2f}, "
            f"findings {row['findings']}"
        )
    lines.append(
        "Each line is also stored as a PREL/Jeeves-style "
        "`belongs_to_category` claim in business_claims."
    )
    return "\n".join(lines)


def _vendor_answer(con: sqlite3.Connection) -> str:
    rows = vendor_summary(con)
    if not rows:
        return "Vendor map\n- no vendor data yet"
    lines = ["Vendor map"]
    for row in rows:
        lines.append(
            f"- {row['vendor']}: category {row['category']}, "
            f"spend ${row['spend']:.2f}, "
            f"exposure ${row['total_exposure']:.2f}, "
            f"findings {row['findings']}"
        )
    return "\n".join(lines)


def _profit_gap_answer() -> str:
    return (
        "Profit/revenue view\n"
        "- not enough source data connected yet\n"
        "- current SQL contains AP invoice spend, price history, OCR evidence, "
        "policy rules, and discrepancy findings\n"
        "- to answer where the business makes the most money, connect sales, "
        "work orders, production output, GL revenue, or job-cost data; then "
        "the same category map can compare revenue, margin, spend, and leakage"
    )


def _output_answer() -> str:
    return (
        "Available data outputs\n"
        "- SQL: invoices, invoice_lines, findings, source_files, business_claims\n"
        "- CSV export: category_summary, vendor_summary, finding_summary, "
        "invoice_lines, top_findings\n"
        "- HTML report: visual business map with category/vendor exposure bars\n"
        "- Slack payload: generated JSON summary; actual posting needs an "
        "explicit webhook configuration"
    )


def _invoice_named_in(con: sqlite3.Connection, question: str) -> str | None:
    q = question.lower()
    rows = con.execute(
        """
        SELECT file_name FROM invoices
        WHERE receipt_id = (SELECT MAX(id) FROM receipts)
        """
    ).fetchall()
    for row in rows:
        name = row["file_name"]
        stem = name.rsplit(".", 1)[0]
        if name.lower() in q or stem.lower() in q:
            return name
    return None
