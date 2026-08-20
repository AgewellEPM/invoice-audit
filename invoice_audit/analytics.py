"""Business analytics, exports, and visual reports over the audit database."""
from __future__ import annotations

import csv
import html
import json
import sqlite3
from pathlib import Path


def latest_receipt_id(con: sqlite3.Connection) -> int | None:
    row = con.execute("SELECT MAX(id) AS id FROM receipts").fetchone()
    return int(row["id"]) if row and row["id"] is not None else None


def overview(con: sqlite3.Connection) -> dict:
    row = con.execute(
        """
        SELECT
            COUNT(DISTINCT i.id) AS invoices,
            COUNT(l.id) AS lines,
            COALESCE(SUM(l.line_total), 0) AS spend,
            COALESCE(SUM(CASE WHEN l.price_verdict = 'overcharge-flag'
                              THEN l.delta_total ELSE 0 END), 0) AS price_exposure,
            COALESCE(SUM(l.policy_delta_total), 0) AS policy_exposure
        FROM invoices i
        LEFT JOIN invoice_lines l ON l.invoice_id = i.id
        WHERE i.receipt_id = (SELECT MAX(id) FROM receipts)
        """
    ).fetchone()
    findings = con.execute(
        """
        SELECT COUNT(*) AS n
        FROM findings
        WHERE receipt_id = (SELECT MAX(id) FROM receipts)
        """
    ).fetchone()
    price_exposure = float(row["price_exposure"] or 0)
    policy_exposure = float(row["policy_exposure"] or 0)
    return {
        "invoices": int(row["invoices"] or 0),
        "lines": int(row["lines"] or 0),
        "spend": round(float(row["spend"] or 0), 2),
        "price_exposure": round(price_exposure, 2),
        "policy_exposure": round(policy_exposure, 2),
        "total_exposure": round(price_exposure + policy_exposure, 2),
        "findings": int(findings["n"] or 0),
    }


def category_summary(con: sqlite3.Connection) -> list[dict]:
    rows = con.execute(
        """
        SELECT
            l.category AS category,
            COUNT(DISTINCT i.id) AS invoices,
            COUNT(*) AS lines,
            COALESCE(SUM(l.line_total), 0) AS spend,
            COALESCE(SUM(CASE WHEN l.price_verdict = 'overcharge-flag'
                              THEN l.delta_total ELSE 0 END), 0) AS price_exposure,
            COALESCE(SUM(l.policy_delta_total), 0) AS policy_exposure,
            COALESCE(MAX(i.vendor), '') AS example_vendor
        FROM invoice_lines l
        JOIN invoices i ON i.id = l.invoice_id
        WHERE i.receipt_id = (SELECT MAX(id) FROM receipts)
        GROUP BY l.category
        """
    ).fetchall()
    finding_counts = _finding_counts_by(con, "COALESCE(l.category, i.category, 'Uncategorized')")
    out = []
    for row in rows:
        price = float(row["price_exposure"] or 0)
        policy = float(row["policy_exposure"] or 0)
        out.append({
            "category": row["category"],
            "invoices": int(row["invoices"] or 0),
            "lines": int(row["lines"] or 0),
            "spend": round(float(row["spend"] or 0), 2),
            "price_exposure": round(price, 2),
            "policy_exposure": round(policy, 2),
            "total_exposure": round(price + policy, 2),
            "findings": finding_counts.get(row["category"], 0),
            "example_vendor": row["example_vendor"],
        })
    return sorted(out, key=lambda r: (r["total_exposure"], r["spend"]), reverse=True)


def vendor_summary(con: sqlite3.Connection) -> list[dict]:
    rows = con.execute(
        """
        SELECT
            i.vendor AS vendor,
            COUNT(DISTINCT i.id) AS invoices,
            COUNT(l.id) AS lines,
            COALESCE(SUM(l.line_total), 0) AS spend,
            COALESCE(SUM(CASE WHEN l.price_verdict = 'overcharge-flag'
                              THEN l.delta_total ELSE 0 END), 0) AS price_exposure,
            COALESCE(SUM(l.policy_delta_total), 0) AS policy_exposure,
            COALESCE(MAX(i.category), 'Uncategorized') AS category
        FROM invoices i
        LEFT JOIN invoice_lines l ON l.invoice_id = i.id
        WHERE i.receipt_id = (SELECT MAX(id) FROM receipts)
        GROUP BY i.vendor
        """
    ).fetchall()
    finding_counts = _finding_counts_by(con, "COALESCE(i.vendor, '')")
    out = []
    for row in rows:
        price = float(row["price_exposure"] or 0)
        policy = float(row["policy_exposure"] or 0)
        out.append({
            "vendor": row["vendor"],
            "category": row["category"],
            "invoices": int(row["invoices"] or 0),
            "lines": int(row["lines"] or 0),
            "spend": round(float(row["spend"] or 0), 2),
            "price_exposure": round(price, 2),
            "policy_exposure": round(policy, 2),
            "total_exposure": round(price + policy, 2),
            "findings": finding_counts.get(row["vendor"], 0),
        })
    return sorted(out, key=lambda r: (r["total_exposure"], r["spend"]), reverse=True)


def finding_summary(con: sqlite3.Connection) -> list[dict]:
    rows = con.execute(
        """
        SELECT severity, kind, COUNT(*) AS n
        FROM findings
        WHERE receipt_id = (SELECT MAX(id) FROM receipts)
        GROUP BY severity, kind
        ORDER BY
            CASE severity
                WHEN 'money' THEN 0
                WHEN 'policy' THEN 1
                WHEN 'evidence' THEN 2
                ELSE 3
            END,
            n DESC,
            kind
        """
    ).fetchall()
    return [
        {
            "severity": row["severity"],
            "kind": row["kind"],
            "findings": int(row["n"] or 0),
        }
        for row in rows
    ]


def top_findings(con: sqlite3.Connection, limit: int = 12) -> list[dict]:
    rows = con.execute(
        """
        SELECT f.kind, f.severity, f.detail,
               i.file_name AS invoice, i.vendor, i.category AS invoice_category,
               l.line_index, l.sku, l.description, l.category AS line_category,
               l.delta_total, l.policy_delta_total, i.path
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
            (COALESCE(l.delta_total, 0) + COALESCE(l.policy_delta_total, 0)) DESC,
            f.id
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    return [
        {
            "severity": row["severity"],
            "kind": row["kind"],
            "detail": row["detail"],
            "invoice": row["invoice"] or "",
            "vendor": row["vendor"] or "",
            "category": row["line_category"] or row["invoice_category"] or "Uncategorized",
            "line": None if row["line_index"] is None else int(row["line_index"]) + 1,
            "sku": row["sku"] or "",
            "description": row["description"] or "",
            "price_exposure": round(float(row["delta_total"] or 0), 2),
            "policy_exposure": round(float(row["policy_delta_total"] or 0), 2),
            "source": row["path"] or "",
        }
        for row in rows
    ]


def invoice_line_rows(con: sqlite3.Connection) -> list[dict]:
    rows = con.execute(
        """
        SELECT i.file_name AS invoice, i.vendor, i.category AS invoice_category,
               l.line_index, l.sku, l.description, l.category AS line_category,
               l.qty, l.unit_price, l.line_total, l.price_verdict,
               l.grounding_verdict, l.floor_verdict,
               l.reference_median, l.delta_total, l.policy_delta_total,
               l.ocr_row_text, i.path AS source
        FROM invoice_lines l
        JOIN invoices i ON i.id = l.invoice_id
        WHERE i.receipt_id = (SELECT MAX(id) FROM receipts)
        ORDER BY i.file_name, l.line_index
        """
    ).fetchall()
    return [
        {
            "invoice": row["invoice"],
            "vendor": row["vendor"],
            "invoice_category": row["invoice_category"],
            "line": int(row["line_index"]) + 1,
            "sku": row["sku"],
            "description": row["description"],
            "line_category": row["line_category"],
            "qty": row["qty"],
            "unit_price": row["unit_price"],
            "line_total": row["line_total"],
            "price_verdict": row["price_verdict"],
            "grounding_verdict": row["grounding_verdict"],
            "floor_verdict": row["floor_verdict"],
            "reference_median": row["reference_median"],
            "price_exposure": row["delta_total"],
            "policy_exposure": row["policy_delta_total"],
            "ocr_row_text": row["ocr_row_text"],
            "source": row["source"],
        }
        for row in rows
    ]


def export_csv(con: sqlite3.Connection, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    outputs = [
        _write_csv(out_dir / "category_summary.csv", category_summary(con)),
        _write_csv(out_dir / "vendor_summary.csv", vendor_summary(con)),
        _write_csv(out_dir / "finding_summary.csv", finding_summary(con)),
        _write_csv(out_dir / "invoice_lines.csv", invoice_line_rows(con)),
        _write_csv(out_dir / "top_findings.csv", top_findings(con, limit=100)),
    ]
    return outputs


def slack_payload(con: sqlite3.Connection) -> dict:
    totals = overview(con)
    categories = category_summary(con)[:5]
    findings = top_findings(con, limit=5)
    lines = [
        f"Invoice Audit: {totals['invoices']} invoices, "
        f"{totals['findings']} findings, "
        f"{_usd(totals['total_exposure'])} potential exposure."
    ]
    for cat in categories:
        lines.append(
            f"{cat['category']}: spend {_usd(cat['spend'])}, "
            f"exposure {_usd(cat['total_exposure'])}, findings {cat['findings']}"
        )
    for finding in findings:
        line = "" if finding["line"] is None else f" line {finding['line']}"
        lines.append(
            f"{finding['severity']}/{finding['kind']}: "
            f"{finding['invoice']}{line} {finding['sku']} — {finding['detail']}"
        )
    return {
        "text": "\n".join(lines),
        "metadata": {
            "event_type": "invoice_audit_summary",
            "event_payload": totals,
        },
    }


def write_slack_payload(con: sqlite3.Connection, out_path: Path) -> Path:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(slack_payload(con), indent=2, sort_keys=True))
    return out_path


def write_html_report(con: sqlite3.Connection, out_path: Path) -> Path:
    totals = overview(con)
    categories = category_summary(con)
    vendors = vendor_summary(con)
    finding_types = finding_summary(con)
    findings = top_findings(con)

    max_category_spend = max([c["spend"] for c in categories] + [1])
    max_category_exposure = max([c["total_exposure"] for c in categories] + [1])
    max_vendor_spend = max([v["spend"] for v in vendors] + [1])
    max_vendor_exposure = max([v["total_exposure"] for v in vendors] + [1])

    html_doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Invoice Audit Business Map</title>
<style>
:root {{
  --bg: #f5f5f7;
  --card: #ffffff;
  --ink: #17181a;
  --muted: #6e737d;
  --line: #e3e5e8;
  --money: #d92d20;
  --policy: #b54708;
  --accent: #0b6bcb;
}}
body {{
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}}
main {{
  max-width: 1180px;
  margin: 0 auto;
  padding: 34px;
}}
h1 {{ margin: 0 0 6px; font-size: 34px; letter-spacing: -0.03em; }}
h2 {{ margin: 0 0 14px; font-size: 18px; }}
p {{ color: var(--muted); }}
.grid {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }}
.card {{
  background: rgba(255,255,255,0.86);
  border: 1px solid var(--line);
  border-radius: 18px;
  padding: 18px;
  box-shadow: 0 18px 40px rgba(10, 17, 30, 0.06);
}}
.metric {{ font-size: 30px; font-weight: 760; letter-spacing: -0.04em; }}
.label {{ color: var(--muted); font-size: 12px; font-weight: 650; text-transform: uppercase; letter-spacing: .06em; }}
.section {{ margin-top: 18px; }}
table {{ width: 100%; border-collapse: collapse; }}
th {{ text-align: left; color: var(--muted); font-size: 12px; padding: 10px 8px; }}
td {{ padding: 12px 8px; border-top: 1px solid var(--line); vertical-align: top; }}
.bar-track {{ height: 9px; background: #edf0f3; border-radius: 99px; overflow: hidden; margin-top: 6px; }}
.bar {{ height: 100%; border-radius: 99px; background: linear-gradient(90deg, #0875e1, #5aa7ff); }}
.bar.risk {{ background: linear-gradient(90deg, #d92d20, #ff9f7a); }}
.pill {{ display: inline-flex; border-radius: 99px; padding: 4px 9px; font-size: 12px; font-weight: 700; background: #edf4ff; color: var(--accent); }}
.sev-money {{ color: var(--money); font-weight: 750; }}
.sev-policy {{ color: var(--policy); font-weight: 750; }}
.sev-evidence {{ color: #475467; font-weight: 750; }}
.two {{ display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }}
.mono {{ font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; color: var(--muted); }}
@media (max-width: 900px) {{ .grid, .two {{ grid-template-columns: 1fr; }} main {{ padding: 18px; }} }}
</style>
</head>
<body>
<main>
  <header>
    <h1>Invoice Audit Business Map</h1>
    <p>Extraction is now connected to categories, SQL rollups, findings, evidence, and export targets. Revenue/profit views require sales, work-order, or production data that is not connected yet.</p>
  </header>

  <section class="grid">
    {_metric_card("Invoices", str(totals["invoices"]))}
    {_metric_card("Spend scanned", _usd(totals["spend"]))}
    {_metric_card("Potential exposure", _usd(totals["total_exposure"]))}
    {_metric_card("Open findings", str(totals["findings"]))}
  </section>

  <section class="section card">
    <h2>Where money is leaking by category</h2>
    {_category_table(categories, max_category_spend, max_category_exposure)}
  </section>

  <section class="section card">
    <h2>Vendor spend and exposure</h2>
    {_vendor_table(vendors, max_vendor_spend, max_vendor_exposure)}
  </section>

  <section class="section two">
    <div class="card">
      <h2>Finding mix</h2>
      {_finding_table(finding_types)}
    </div>
    <div class="card">
      <h2>Output map</h2>
      <table>
        <tr><td><span class="pill">SQL</span></td><td>durable backend tables for invoices, lines, findings, and Jeeves/PREL-style claims</td></tr>
        <tr><td><span class="pill">CSV</span></td><td>category, vendor, finding, line-item, and top-finding exports</td></tr>
        <tr><td><span class="pill">Slack</span></td><td>generated JSON payload; actual sending waits for a configured webhook</td></tr>
        <tr><td><span class="pill">Report</span></td><td>this visual business map, generated directly from SQLite</td></tr>
      </table>
    </div>
  </section>

  <section class="section card">
    <h2>Review queue with evidence trail</h2>
    {_top_findings_table(findings)}
  </section>
</main>
</body>
</html>
"""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(html_doc)
    return out_path


def analytics_text(con: sqlite3.Connection) -> str:
    totals = overview(con)
    lines = [
        "Business map",
        f"- invoices: {totals['invoices']}",
        f"- lines: {totals['lines']}",
        f"- scanned spend: {_usd(totals['spend'])}",
        f"- potential exposure: {_usd(totals['total_exposure'])} "
        f"(price {_usd(totals['price_exposure'])}; policy {_usd(totals['policy_exposure'])})",
        "",
        "Categories",
    ]
    for row in category_summary(con):
        lines.append(
            f"- {row['category']}: spend {_usd(row['spend'])}, "
            f"exposure {_usd(row['total_exposure'])}, "
            f"findings {row['findings']}, lines {row['lines']}"
        )
    lines.extend(["", "Vendors"])
    for row in vendor_summary(con):
        lines.append(
            f"- {row['vendor']}: spend {_usd(row['spend'])}, "
            f"exposure {_usd(row['total_exposure'])}, "
            f"findings {row['findings']}, category {row['category']}"
        )
    lines.extend([
        "",
        "Profit/revenue note: this database currently contains AP invoice spend,"
        " price history, policy rules, and OCR evidence. To answer where the"
        " business is making the most money, connect sales, work-order,"
        " production, or GL revenue sources next.",
    ])
    return "\n".join(lines)


def _finding_counts_by(con: sqlite3.Connection, expr: str) -> dict[str, int]:
    rows = con.execute(
        f"""
        SELECT {expr} AS key, COUNT(f.id) AS findings
        FROM findings f
        LEFT JOIN invoices i ON i.id = f.invoice_id
        LEFT JOIN invoice_lines l ON l.id = f.line_id
        WHERE f.receipt_id = (SELECT MAX(id) FROM receipts)
        GROUP BY {expr}
        """
    ).fetchall()
    return {row["key"]: int(row["findings"] or 0) for row in rows}


def _write_csv(path: Path, rows: list[dict]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        if not rows:
            f.write("")
            return path
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    return path


def _metric_card(label: str, value: str) -> str:
    return (
        '<div class="card">'
        f'<div class="label">{_h(label)}</div>'
        f'<div class="metric">{_h(value)}</div>'
        '</div>'
    )


def _category_table(rows: list[dict], max_spend: float, max_exposure: float) -> str:
    if not rows:
        return "<p>No category data.</p>"
    body = []
    for row in rows:
        body.append(
            "<tr>"
            f"<td><strong>{_h(row['category'])}</strong><br><span class='mono'>{row['lines']} lines · {row['findings']} findings</span></td>"
            f"<td>{_usd(row['spend'])}{_bar(row['spend'], max_spend)}</td>"
            f"<td>{_usd(row['total_exposure'])}{_bar(row['total_exposure'], max_exposure, risk=True)}</td>"
            f"<td>{_usd(row['price_exposure'])}</td>"
            f"<td>{_usd(row['policy_exposure'])}</td>"
            f"<td>{_h(row['example_vendor'])}</td>"
            "</tr>"
        )
    return (
        "<table><thead><tr><th>Category</th><th>Spend</th><th>Total exposure</th>"
        "<th>Price exposure</th><th>Policy exposure</th><th>Example vendor</th></tr></thead>"
        f"<tbody>{''.join(body)}</tbody></table>"
    )


def _vendor_table(rows: list[dict], max_spend: float, max_exposure: float) -> str:
    if not rows:
        return "<p>No vendor data.</p>"
    body = []
    for row in rows:
        body.append(
            "<tr>"
            f"<td><strong>{_h(row['vendor'])}</strong><br><span class='mono'>{_h(row['category'])}</span></td>"
            f"<td>{row['invoices']}</td>"
            f"<td>{_usd(row['spend'])}{_bar(row['spend'], max_spend)}</td>"
            f"<td>{_usd(row['total_exposure'])}{_bar(row['total_exposure'], max_exposure, risk=True)}</td>"
            f"<td>{row['findings']}</td>"
            "</tr>"
        )
    return (
        "<table><thead><tr><th>Vendor</th><th>Invoices</th><th>Spend</th>"
        "<th>Exposure</th><th>Findings</th></tr></thead>"
        f"<tbody>{''.join(body)}</tbody></table>"
    )


def _finding_table(rows: list[dict]) -> str:
    if not rows:
        return "<p>No findings.</p>"
    body = []
    for row in rows:
        body.append(
            "<tr>"
            f"<td class='sev-{_h(row['severity'])}'>{_h(row['severity'])}</td>"
            f"<td>{_h(row['kind'])}</td>"
            f"<td>{row['findings']}</td>"
            "</tr>"
        )
    return "<table><thead><tr><th>Severity</th><th>Kind</th><th>Count</th></tr></thead><tbody>" + "".join(body) + "</tbody></table>"


def _top_findings_table(rows: list[dict]) -> str:
    if not rows:
        return "<p>No open findings.</p>"
    body = []
    for row in rows:
        line = "invoice" if row["line"] is None else f"line {row['line']}"
        body.append(
            "<tr>"
            f"<td class='sev-{_h(row['severity'])}'>{_h(row['severity'])}</td>"
            f"<td><strong>{_h(row['kind'])}</strong><br><span class='mono'>{_h(row['category'])}</span></td>"
            f"<td>{_h(row['invoice'])}<br><span class='mono'>{_h(line)} {_h(row['sku'])}</span></td>"
            f"<td>{_h(row['detail'])}<br><span class='mono'>{_h(row['source'])}</span></td>"
            "</tr>"
        )
    return "<table><thead><tr><th>Severity</th><th>Finding</th><th>Invoice</th><th>Evidence</th></tr></thead><tbody>" + "".join(body) + "</tbody></table>"


def _bar(value: float, max_value: float, *, risk: bool = False) -> str:
    width = 0 if max_value <= 0 else max(3, min(100, int((value / max_value) * 100)))
    cls = "bar risk" if risk else "bar"
    return f'<div class="bar-track"><div class="{cls}" style="width:{width}%"></div></div>'


def _usd(value: float) -> str:
    return f"${float(value):,.2f}"


def _h(value: object) -> str:
    return html.escape(str(value), quote=True)
