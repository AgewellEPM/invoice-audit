"""CLI — audit scans, persist findings, verify receipts.

  python3 -m invoice_audit audit <scans-dir> --pricebook <xlsx|csv|sqlite> [--market <csv|sqlite>]
  python3 -m invoice_audit audit-db <scans-dir> --pricebook <xlsx|csv|sqlite> --db business.sqlite
  python3 -m invoice_audit connector-presets
  python3 -m invoice_audit connector-init --kind local-folder --out source.json ...
  python3 -m invoice_audit connector-sync --config source.json --workspace .sources
  python3 -m invoice_audit audit-connector --config source.json --workspace .sources --db business.sqlite
  python3 -m invoice_audit findings --db business.sqlite
  python3 -m invoice_audit ask --db business.sqlite "show overcharges"
  python3 -m invoice_audit analytics --db business.sqlite
  python3 -m invoice_audit history --db business.sqlite --json
  python3 -m invoice_audit export --db business.sqlite --out exports/
  python3 -m invoice_audit report --db business.sqlite --out report.html
  python3 -m invoice_audit slack-payload --db business.sqlite --out slack.json
  python3 -m invoice_audit email-draft --db business.sqlite --out boss-summary.eml
  python3 -m invoice_audit integration-payload --db business.sqlite --out api.json
  python3 -m invoice_audit send-webhook --db business.sqlite --url <zapier-hook-url>
  python3 -m invoice_audit legacy-status --json --scan
  python3 -m invoice_audit watch <scans-dir> --pricebook <xlsx|csv|sqlite> --db business.sqlite
  python3 -m invoice_audit verify <receipt.json>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .analytics import (
    analytics_text, business_history, export_csv, history_text, send_webhook, write_email_draft,
    write_html_report, write_integration_payload, write_slack_payload)
from .analyst import answer_question
from .audit import audit_folder
from .benchmark import items_from_receipt, refresh_all, refresh_item
from .connectors import (
    ConnectorConfig, connector_presets, sync_connector, write_connector_config)
from .kist_bridge import KIST_MODES, KistResearchError, kist_available
from .legacy_bridge import bridge_status, legacy_status_text
from .ocr import AuditError
from . import primitives
from .savings import savings_report, savings_text
from .store import connect, list_findings, store_receipt
from .watcher import run_once_if_changed, watch_loop


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="invoice-audit")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("audit", help="audit a folder of invoice scans")
    a.add_argument("scans_dir", type=Path)
    a.add_argument("--pricebook", type=Path, required=True)
    a.add_argument("--market", type=Path, default=None,
                   help="optional market benchmark CSV/SQLite")
    a.add_argument("--market-benchmarks", type=Path, default=None,
                   help="optional kist research provenance sidecar (JSON) to bind into the receipt")
    a.add_argument("--floor", type=Path, default=None,
                   help="taught vendor/domain rules (JSON) — symbolic veto layer")
    a.add_argument("--tolerance", type=float, default=0.15)
    a.add_argument("--out", type=Path, default=None)

    adb = sub.add_parser("audit-db", help="audit scans and persist into SQLite")
    adb.add_argument("scans_dir", type=Path)
    adb.add_argument("--pricebook", type=Path, required=True)
    adb.add_argument("--market", type=Path, default=None,
                     help="optional market benchmark CSV/SQLite")
    adb.add_argument("--market-benchmarks", type=Path, default=None,
                     help="optional kist research provenance sidecar (JSON)")
    adb.add_argument("--floor", type=Path, default=None,
                     help="taught vendor/domain rules (JSON)")
    adb.add_argument("--tolerance", type=float, default=0.15)
    adb.add_argument("--db", type=Path, required=True)
    adb.add_argument("--out", type=Path, default=None,
                     help="optional signed receipt JSON path")

    cp = sub.add_parser("connector-presets", help="list point-click inbound source options")
    cp.add_argument("--json", action="store_true")

    ci = sub.add_parser("connector-init", help="write an inbound connector config")
    ci.add_argument("--kind", required=True)
    ci.add_argument("--name", default="")
    ci.add_argument("--invoices", default="")
    ci.add_argument("--pricebook", default="")
    ci.add_argument("--floor", default="")
    ci.add_argument("--url", default="")
    ci.add_argument("--token-env", default="")
    ci.add_argument("--mbox", default="")
    ci.add_argument("--out", type=Path, required=True)

    cs = sub.add_parser("connector-sync", help="pull connector data into a managed workspace")
    cs.add_argument("--config", type=Path, required=True)
    cs.add_argument("--workspace", type=Path, required=True)

    ac = sub.add_parser("audit-connector", help="sync a connector, then audit it")
    ac.add_argument("--config", type=Path, required=True)
    ac.add_argument("--workspace", type=Path, required=True)
    ac.add_argument("--db", type=Path, required=True)
    ac.add_argument("--out", type=Path, default=None)
    ac.add_argument("--market", type=Path, default=None)
    ac.add_argument("--tolerance", type=float, default=0.15)

    f = sub.add_parser("findings", help="list findings from SQLite")
    f.add_argument("--db", type=Path, required=True)
    f.add_argument("--limit", type=int, default=50)

    ask = sub.add_parser("ask", help="ask the SQL-backed business analyst")
    ask.add_argument("question")
    ask.add_argument("--db", type=Path, required=True)

    an = sub.add_parser("analytics", help="show category/vendor exposure map from SQLite")
    an.add_argument("--db", type=Path, required=True)

    hist = sub.add_parser("history", help="show CEO attention journal from SQLite")
    hist.add_argument("--db", type=Path, required=True)
    hist.add_argument("--limit", type=int, default=8)
    hist.add_argument("--json", action="store_true")

    ex = sub.add_parser("export", help="export business-analysis CSVs from SQLite")
    ex.add_argument("--db", type=Path, required=True)
    ex.add_argument("--out", type=Path, required=True)

    rep = sub.add_parser("report", help="write a visual HTML business map")
    rep.add_argument("--db", type=Path, required=True)
    rep.add_argument("--out", type=Path, required=True)

    sp = sub.add_parser("slack-payload", help="write Slack-ready JSON without sending it")
    sp.add_argument("--db", type=Path, required=True)
    sp.add_argument("--out", type=Path, required=True)

    ed = sub.add_parser("email-draft", help="write a boss-ready .eml draft")
    ed.add_argument("--db", type=Path, required=True)
    ed.add_argument("--out", type=Path, required=True)
    ed.add_argument("--to", default="")
    ed.add_argument("--from-addr", default="invoice-audit@local")
    ed.add_argument("--attach-report", type=Path, default=None)

    ip = sub.add_parser("integration-payload", help="write generic API/Zapier JSON")
    ip.add_argument("--db", type=Path, required=True)
    ip.add_argument("--out", type=Path, required=True)

    wh = sub.add_parser("send-webhook", help="send generic API/Zapier JSON to a webhook URL")
    wh.add_argument("--db", type=Path, required=True)
    wh.add_argument("--url", required=True)
    wh.add_argument("--timeout", type=float, default=10.0)

    ls = sub.add_parser("legacy-status", help="inspect local Kist/Perslis/VM/RM bridge state")
    ls.add_argument("--url", default="http://127.0.0.1:8765")
    ls.add_argument("--scan", action="store_true",
                    help="also call /api/vm-stage-scan to prove vision status")
    ls.add_argument("--json", action="store_true")
    ls.add_argument("--no-fail", action="store_true",
                    help="always exit 0 after printing status JSON/text")

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
    v.add_argument("--json", action="store_true",
                   help="emit the structured VerificationResult (exit 0 when the "
                        "result is produced; the verdict is the `ok` field, not the exit code)")

    br = sub.add_parser("benchmark-refresh",
                        help="research industry market prices via kist into a cache")
    br.add_argument("--receipt", type=Path, required=True,
                    help="signed receipt whose items to benchmark")
    br.add_argument("--cache-dir", type=Path, required=True)
    br.add_argument("--region", default="United States")
    br.add_argument("--mode", default="dig", choices=KIST_MODES,
                    help="kist research mode (dig = every model cross-compared)")
    br.add_argument("--force", action="store_true",
                    help="ignore cache freshness and re-research every item")
    br.add_argument("--max-age-days", type=int, default=30)
    br.add_argument("--json", action="store_true")

    bi = sub.add_parser("benchmark-item",
                        help="force a fresh live kist dig for ONE item")
    bi.add_argument("--sku", default="")
    bi.add_argument("--description", default="")
    bi.add_argument("--cache-dir", type=Path, required=True)
    bi.add_argument("--region", default="United States")
    bi.add_argument("--mode", default="dig", choices=KIST_MODES)

    sv = sub.add_parser("savings", help="show the savings/value story from a receipt")
    sv.add_argument("receipt", type=Path)
    sv.add_argument("--json", action="store_true")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "audit":
            receipt = audit_folder(args.scans_dir, args.pricebook,
                                   tolerance=args.tolerance,
                                   floor_path=args.floor,
                                   market_path=args.market,
                                   market_benchmarks_path=args.market_benchmarks)
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
                                   floor_path=args.floor,
                                   market_path=args.market,
                                   market_benchmarks_path=args.market_benchmarks)
            if args.out:
                args.out.write_text(json.dumps(receipt, indent=2, sort_keys=True))
            with connect(args.db) as con:
                receipt_id = store_receipt(con, receipt)
            t = receipt["totals"]
            print(f"stored receipt_id={receipt_id} db={args.db}")
            print(f"invoices={t['invoices']} lines={t['linesChecked']} "
                  f"flagged={t['flagged']} "
                  f"potentialOverchargeUSD={t['potentialOverchargeUSD']:.2f} "
                  f"marketOverchargeUSD={t.get('marketOverchargeUSD', 0):.2f} "
                  f"policyOverageUSD={t['policyOverageUSD']:.2f}")
            return 0
        if args.cmd == "connector-presets":
            presets = connector_presets()
            if args.json:
                print(json.dumps(presets, indent=2, sort_keys=True))
            else:
                for preset in presets:
                    print(f"{preset['kind']}: {preset['label']} [{preset['status']}]")
                    print(f"  {preset['description']}")
            return 0
        if args.cmd == "connector-init":
            path = write_connector_config(
                ConnectorConfig(
                    kind=args.kind,
                    name=args.name or args.kind,
                    invoices=args.invoices,
                    pricebook=args.pricebook,
                    floor=args.floor,
                    url=args.url,
                    token_env=args.token_env,
                    mbox=args.mbox,
                ),
                args.out,
            )
            print(path)
            return 0
        if args.cmd == "connector-sync":
            manifest = sync_connector(args.config, args.workspace)
            print(json.dumps(manifest, indent=2, sort_keys=True))
            return 0
        if args.cmd == "audit-connector":
            manifest = sync_connector(args.config, args.workspace)
            floor = Path(manifest["floor"]) if manifest.get("floor") else None
            receipt = audit_folder(
                Path(manifest["scans_dir"]),
                Path(manifest["pricebook"]),
                tolerance=args.tolerance,
                floor_path=floor,
                market_path=args.market,
            )
            if args.out:
                args.out.write_text(json.dumps(receipt, indent=2, sort_keys=True))
            with connect(args.db) as con:
                receipt_id = store_receipt(con, receipt)
            t = receipt["totals"]
            print(f"stored receipt_id={receipt_id} db={args.db}")
            print(f"connector={manifest['connector']['name']} "
                  f"invoices={t['invoices']} flagged={t['flagged']} "
                  f"dataQualityIssues={t.get('dataQualityIssues', 0)}")
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
        if args.cmd == "history":
            with connect(args.db) as con:
                if args.json:
                    print(json.dumps(business_history(con, limit=args.limit), indent=2, sort_keys=True))
                else:
                    print(history_text(con, limit=args.limit))
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
        if args.cmd == "email-draft":
            with connect(args.db) as con:
                path = write_email_draft(
                    con,
                    args.out,
                    to_addr=args.to,
                    from_addr=args.from_addr,
                    attach_report=args.attach_report,
                )
            print(path)
            return 0
        if args.cmd == "integration-payload":
            with connect(args.db) as con:
                path = write_integration_payload(con, args.out)
            print(path)
            return 0
        if args.cmd == "send-webhook":
            with connect(args.db) as con:
                result = send_webhook(con, args.url, timeout=args.timeout)
            print(json.dumps(result, sort_keys=True))
            return 0 if result.get("ok") else 1
        if args.cmd == "legacy-status":
            status = bridge_status(args.url, include_scan=args.scan)
            if args.json:
                print(json.dumps(status, indent=2, sort_keys=True))
            else:
                print(legacy_status_text(status))
            return 0 if args.no_fail or status.get("ok") else 1
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
            # One path to verification: the primitive. No direct call, no
            # bespoke re-check here — CLI and Swift both consume this result.
            result = primitives.verify(receipt, rehash_inputs=not args.no_rehash)
            if args.json:
                # The verdict lives in the JSON `ok` field. Exit 0 whenever a
                # result was produced so a structured consumer (Swift) can read
                # `ok`/`problems` instead of a non-zero exit collapsing a real
                # "needs attention" into a generic process failure.
                print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
                return 0
            if not result.ok:
                for p in result.problems:
                    print(f"FAIL {p}", file=sys.stderr)
                return 1
            print("VERIFIED — signature valid"
                  + ("" if args.no_rehash else ", input hashes match")
                  + f" [{result.rule_version}]")
            return 0
        if args.cmd == "benchmark-refresh":
            receipt = json.loads(args.receipt.read_text())
            items = items_from_receipt(receipt)
            result = refresh_all(items, args.cache_dir, region=args.region,
                                 mode=args.mode, force=args.force,
                                 max_age_days=args.max_age_days)
            payload = result.to_dict()
            payload["kistAvailable"] = kist_available()
            if args.json:
                print(json.dumps(payload, indent=2, sort_keys=True))
            else:
                print(f"researched={result.researched} reused={result.reused} "
                      f"priced={len(result.quotes)} failures={len(result.failures)}")
                print(f"marketCsv={result.market_csv}")
                print(f"sidecar={result.sidecar}")
                for f in result.failures:
                    print(f"  UNPRICED [{f['reason']}] {f['sku']} {f['description']}")
            return 0
        if args.cmd == "benchmark-item":
            if not args.sku and not args.description:
                print("invoice-audit: benchmark-item needs --sku or --description",
                      file=sys.stderr)
                return 2
            try:
                quote = refresh_item(args.sku, args.description, args.cache_dir,
                                     region=args.region, mode=args.mode)
            except KistResearchError as e:
                print(json.dumps({"ok": False, "reason": e.reason,
                                  "detail": e.detail}))
                return 1
            print(json.dumps({"ok": True, **quote.to_dict()},
                             indent=2, sort_keys=True))
            return 0
        if args.cmd == "savings":
            receipt = json.loads(args.receipt.read_text())
            if args.json:
                print(json.dumps(savings_report(receipt), indent=2, sort_keys=True))
            else:
                print(savings_text(receipt))
            return 0
    except AuditError as e:
        print(f"invoice-audit: {e}", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"invoice-audit: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
