"""CLI — audit a folder of scans, verify a receipt.

  python3 -m invoice_audit audit <scans-dir> --pricebook <csv|sqlite> [--out receipt.json]
  python3 -m invoice_audit verify <receipt.json>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .audit import audit_folder
from .ocr import AuditError
from .receipt import verify_receipt


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="invoice-audit")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("audit", help="audit a folder of invoice scans")
    a.add_argument("scans_dir", type=Path)
    a.add_argument("--pricebook", type=Path, required=True)
    a.add_argument("--tolerance", type=float, default=0.15)
    a.add_argument("--out", type=Path, default=None)

    v = sub.add_parser("verify", help="re-verify a signed receipt")
    v.add_argument("receipt", type=Path)
    v.add_argument("--no-rehash", action="store_true",
                   help="check signature only (inputs not present here)")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "audit":
            receipt = audit_folder(args.scans_dir, args.pricebook,
                                   tolerance=args.tolerance)
            out = args.out or (args.scans_dir / "audit-receipt.json")
            out.write_text(json.dumps(receipt, indent=2, sort_keys=True))
            t = receipt["totals"]
            print(f"invoices={t['invoices']} lines={t['linesChecked']} "
                  f"flagged={t['flagged']} "
                  f"potentialOverchargeUSD={t['potentialOverchargeUSD']:.2f}")
            for item in receipt["reviewQueue"]:
                print(f"  REVIEW [{item['kind']}] {item['invoice']}"
                      f" line={item.get('line')} — {item['detail']}")
            print(f"receipt={out} (signed)")
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
