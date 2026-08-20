"""CLI — audit scans, persist findings, verify receipts.

  python3 -m invoice_audit audit <scans-dir> --pricebook <csv|sqlite> [--out receipt.json]
  python3 -m invoice_audit audit-db <scans-dir> --pricebook <csv|sqlite> --db business.sqlite
  python3 -m invoice_audit findings --db business.sqlite
  python3 -m invoice_audit ask --db business.sqlite "show overcharges"
  python3 -m invoice_audit analytics --db business.sqlite
  python3 -m invoice_audit export --db business.sqlite --out exports/
  python3 -m invoice_audit report --db business.sqlite --out report.html
  python3 -m invoice_audit slack-payload --db business.sqlite --out slack.json
  python3 -m invoice_audit watch <scans-dir> --pricebook <csv|sqlite> --db business.sqlite
  python3 -m invoice_audit verify <receipt.json>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .analytics import analytics_text, export_csv, write_html_report, write_slack_payload
from .analyst import answer_question
from .audit import audit_folder
from .ocr import AuditError
from .receipt import verify_receipt
from .store import connect, list_findings, store_receipt
from .watcher import run_once_if_changed, watch_loop


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="invoice-audit")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("audit", help="audit a folder of invoice scans")
    a.add_argument("scans_dir", type=Path)
    a.add_argument("--pricebook", type=Path, required=True)
    a.add_argument("--floor", type=Path, default=None,
                   help="taught vendor/domain rules (JSON) — symbolic veto layer")
    a.add_argument("--tolerance", type=float, default=0.15)
    a.add_argument("--out", type=Path, default=None)

    adb = sub.add_parser("audit-db", help="audit scans and persist into SQLite")
    adb.add_argument("scans_dir", type=Path)
    adb.add_argument("--pricebook", type=Path, required=True)
    adb.add_argument("--floor", type=Path, default=None,
                     help="taught vendor/domain rules (JSON)")
    adb.add_argument("--tolerance", type=float, default=0.15)
    adb.add_argument("--db", type=Path, required=True)
    adb.add_argument("--out", type=Path, default=None,
                     help="optional signed receipt JSON path")

    f = sub.add_parser("findings", help="list findings from SQLite")
    f.add_argument("--db", type=Path, required=True)
    f.add_argument("--limit", type=int, default=50)

    ask = sub.add_parser("ask", help="ask the SQL-backed business analyst")
    ask.add_argument("question")
    ask.add_argument("--db", type=Path, required=True)

    an = sub.add_parser("analytics", help="show category/vendor exposure map from SQLite")
    an.add_argument("--db", type=Path, required=True)

    ex = sub.add_parser("export", help="export business-analysis CSVs from SQLite")
    ex.add_argument("--db", type=Path, required=True)
    ex.add_argument("--out", type=Path, required=True)

    rep = sub.add_parser("report", help="write a visual HTML business map")
    rep.add_argument("--db", type=Path, required=True)
    rep.add_argument("--out", type=Path, required=True)

    sp = sub.add_parser("slack-payload", help="write Slack-ready JSON without sending it")
    sp.add_argument("--db", type=Path, required=True)
    sp.add_argument("--out", type=Path, required=True)

    w = sub.add_parser("watch", help="continuously audit when sources change")
    w.add_argument("scans_dir", type=Path)
    w.add_argument("--pricebook", type=Path, required=True)
    w.add_argument("--floor", type=Path, default=None)
    w.add_argument("--db", type=Path, required=True)
    w.add_argument("--out", type=Path, default=None,
                   help="optional latest signed receipt JSON path")
    w.add_argument("--state", type=Path, default=None,
                   help="watch state JSON path")
    w.add_argument("--tolerance", type=float, default=0.15)
    w.add_argument("--interval", type=float, default=30.0)
    w.add_argument("--once", action="store_true",
                   help="check once and exit")

    v = sub.add_parser("verify", help="re-verify a signed receipt")
    v.add_argument("receipt", type=Path)
    v.add_argument("--no-rehash", action="store_true",
                   help="check signature only (inputs not present here)")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "audit":
            receipt = audit_folder(args.scans_dir, args.pricebook,
                                   tolerance=args.tolerance,
                                   floor_path=args.floor)
            out = args.out or (args.scans_dir / "audit-receipt.json")
            out.write_text(json.dumps(receipt, indent=2, sort_keys=True))
            t = receipt["totals"]
            print(f"invoices={t['invoices']} lines={t['linesChecked']} "
                  f"flagged={t['flagged']} "
                  f"potentialOverchargeUSD={t['potentialOverchargeUSD']:.2f} "
                  f"policyOverageUSD={t['policyOverageUSD']:.2f}")
            for item in receipt["reviewQueue"]:
                print(f"  REVIEW [{item['kind']}] {item['invoice']}"
                      f" line={item.get('line')} — {item['detail']}")
            print(f"receipt={out} (signed)")
            return 0
        if args.cmd == "audit-db":
            receipt = audit_folder(args.scans_dir, args.pricebook,
                                   tolerance=args.tolerance,
                                   floor_path=args.floor)
            if args.out:
                args.out.write_text(json.dumps(receipt, indent=2, sort_keys=True))
            with connect(args.db) as con:
                receipt_id = store_receipt(con, receipt)
            t = receipt["totals"]
            print(f"stored receipt_id={receipt_id} db={args.db}")
            print(f"invoices={t['invoices']} lines={t['linesChecked']} "
                  f"flagged={t['flagged']} "
                  f"potentialOverchargeUSD={t['potentialOverchargeUSD']:.2f} "
                  f"policyOverageUSD={t['policyOverageUSD']:.2f}")
            return 0
        if args.cmd == "findings":
            with connect(args.db) as con:
                rows = list_findings(con, limit=args.limit)
            for row in rows:
                line = "" if row["line_index"] is None else f" line={row['line_index'] + 1}"
                sku = "" if not row["sku"] else f" sku={row['sku']}"
                print(f"[{row['severity']}] {row['kind']} {row['invoice'] or ''}"
                      f"{line}{sku} — {row['detail']}")
            if not rows:
                print("no findings")
            return 0
        if args.cmd == "ask":
            with connect(args.db) as con:
                print(answer_question(con, args.question))
            return 0
        if args.cmd == "analytics":
            with connect(args.db) as con:
                print(analytics_text(con))
            return 0
        if args.cmd == "export":
            with connect(args.db) as con:
                outputs = export_csv(con, args.out)
            for path in outputs:
                print(path)
            return 0
        if args.cmd == "report":
            with connect(args.db) as con:
                path = write_html_report(con, args.out)
            print(path)
            return 0
        if args.cmd == "slack-payload":
            with connect(args.db) as con:
                path = write_slack_payload(con, args.out)
            print(path)
            return 0
        if args.cmd == "watch":
            if args.once:
                result = run_once_if_changed(
                    args.scans_dir,
                    args.pricebook,
                    args.db,
                    floor_path=args.floor,
                    state_path=args.state,
                    receipt_path=args.out,
                    tolerance=args.tolerance,
                )
                if result["changed"]:
                    t = result.get("totals", {})
                    print(f"changed receipt_id={result['receipt_id']} "
                          f"invoices={t.get('invoices', 0)} "
                          f"flagged={t.get('flagged', 0)}")
                else:
                    print(result["reason"])
                return 0
            watch_loop(
                args.scans_dir,
                args.pricebook,
                args.db,
                floor_path=args.floor,
                state_path=args.state,
                receipt_path=args.out,
                tolerance=args.tolerance,
                interval=args.interval,
            )
            return 0
        if args.cmd == "verify":
            receipt = json.loads(args.receipt.read_text())
            problems = verify_receipt(receipt,
                                      rehash_inputs=not args.no_rehash)
            if problems:
                for p in problems:
                    print(f"FAIL {p}", file=sys.stderr)
                return 1
            print("VERIFIED — signature valid"
                  + ("" if args.no_rehash else ", input hashes match"))
            return 0
    except AuditError as e:
        print(f"invoice-audit: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
