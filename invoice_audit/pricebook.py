"""Reference-price check — the customer's OWN purchase history is the truth.

There is no magic "market price" API for industrial parts; the check that
catches the $6,000 forklift invoice is "you paid $2,950 for this exact part
in March." Sources: a CSV or SQLite price history (Data-Exchange-compatible
shapes). Verdicts are fail-closed: a line with NO reference history is
flagged `no-reference` for a human — it is never silently passed.
"""
from __future__ import annotations

import csv
import re
import sqlite3
import statistics
from dataclasses import dataclass
from pathlib import Path

from .layout import LineItem
from .ocr import AuditError, sha256_file

# Flag when invoice unit price exceeds reference median by this ratio…
DEFAULT_TOLERANCE = 0.15
# …and by at least this many dollars (a 20% jump on a $2 part is noise).
ABSOLUTE_FLOOR = 5.00


@dataclass(frozen=True)
class ReferenceRow:
    sku: str
    description: str
    unit_price: float


def _norm(text: str) -> str:
    return re.sub(r"[^A-Z0-9 ]", "", text.upper()).strip()


class PriceBook:
    def __init__(self, rows: list[ReferenceRow], source: Path):
        if not rows:
            raise AuditError(f"pricebook-empty:{source.name}")
        self.rows = rows
        self.source = source
        self.source_sha256 = sha256_file(source)
        self._by_sku: dict[str, list[float]] = {}
        self._by_desc: dict[str, list[float]] = {}
        for r in rows:
            if r.sku:
                self._by_sku.setdefault(_norm(r.sku), []).append(r.unit_price)
            if r.description:
                self._by_desc.setdefault(_norm(r.description), []).append(r.unit_price)

    @classmethod
    def load(cls, path: Path) -> "PriceBook":
        if not path.exists():
            raise AuditError(f"pricebook-missing:{path}")
        if path.suffix.lower() == ".csv":
            return cls(cls._from_csv(path), path)
        if path.suffix.lower() in (".sqlite", ".db", ".sqlite3"):
            return cls(cls._from_sqlite(path), path)
        raise AuditError(f"pricebook-unsupported-format:{path.suffix}")

    @staticmethod
    def _from_csv(path: Path) -> list[ReferenceRow]:
        rows: list[ReferenceRow] = []
        with open(path, newline="") as f:
            for rec in csv.DictReader(f):
                keys = {k.lower().strip(): (v or "").strip() for k, v in rec.items()}
                try:
                    rows.append(ReferenceRow(
                        sku=keys.get("sku", ""),
                        description=keys.get("description", ""),
                        unit_price=float(keys.get("unit_price", keys.get("price", ""))),
                    ))
                except ValueError as e:
                    raise AuditError(f"pricebook-bad-row:{rec}") from e
        return rows

    @staticmethod
    def _from_sqlite(path: Path) -> list[ReferenceRow]:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            cur = con.execute(
                "SELECT sku, description, unit_price FROM price_history")
            return [ReferenceRow(str(s or ""), str(d or ""), float(p))
                    for s, d, p in cur.fetchall()]
        except sqlite3.Error as e:
            raise AuditError(f"pricebook-sqlite:{e}") from e
        finally:
            con.close()

    def check(self, line: LineItem, tolerance: float = DEFAULT_TOLERANCE) -> dict:
        """Verdict for one line: ok | overcharge-flag | no-reference."""
        history = None
        matched_on = None
        if line.sku and _norm(line.sku) in self._by_sku:
            history, matched_on = self._by_sku[_norm(line.sku)], f"sku:{line.sku}"
        elif _norm(line.description) in self._by_desc:
            history = self._by_desc[_norm(line.description)]
            matched_on = "description"
        if history is None:
            return {"verdict": "no-reference", "matched_on": None,
                    "detail": "no purchase history for this item — human review"}
        ref = statistics.median(history)
        delta = round(line.unit_price - ref, 2)
        over = delta > max(ref * tolerance, ABSOLUTE_FLOOR)
        return {
            "verdict": "overcharge-flag" if over else "ok",
            "matched_on": matched_on,
            "reference_median": round(ref, 2),
            "reference_samples": len(history),
            "invoice_unit": line.unit_price,
            "delta_per_unit": delta,
            "delta_total": round(delta * line.qty, 2) if over else 0.0,
            "detail": (f"unit {line.unit_price:.2f} vs median {ref:.2f} "
                       f"(n={len(history)})"),
        }
