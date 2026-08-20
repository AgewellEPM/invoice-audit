"""Reference-price check — the customer's OWN purchase history is the truth.

There is no magic "market price" API for industrial parts; the check that
catches the $6,000 forklift invoice is "you paid $2,950 for this exact part
in March." Sources: Excel, CSV, or SQLite price history
(Data-Exchange-compatible shapes). Verdicts are fail-closed: a line with NO
reference history is
flagged `no-reference` for a human — it is never silently passed.
"""
from __future__ import annotations

import csv
import re
import sqlite3
import statistics
import zipfile
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

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


FIELD_ALIASES = {
    "sku": ("sku", "part", "part_number", "part number", "item", "item number", "item_no"),
    "description": ("description", "desc", "item description", "name", "part description"),
    "unit_price": (
        "unit_price", "unit price", "price", "unit cost", "cost",
        "last price", "median price", "paid price",
    ),
}


def _header_key(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower().replace("-", " ").replace("_", " "))


def _field(row: dict[str, str], logical_name: str) -> str:
    for alias in FIELD_ALIASES[logical_name]:
        key = _header_key(alias)
        if key in row:
            return row[key]
    return ""


def _xlsx_shared_strings(zf: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in zf.namelist():
        return []
    root = ET.fromstring(zf.read("xl/sharedStrings.xml"))
    ns = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    strings = []
    for item in root.findall("x:si", ns):
        text = "".join(node.text or "" for node in item.findall(".//x:t", ns))
        strings.append(text)
    return strings


def _xlsx_sheet_matrix(sheet_xml: bytes, shared: list[str]) -> list[list[str]]:
    root = ET.fromstring(sheet_xml)
    ns = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    rows: list[list[str]] = []
    for row in root.findall(".//x:sheetData/x:row", ns):
        values: dict[int, str] = {}
        for cell in row.findall("x:c", ns):
            ref = cell.attrib.get("r", "")
            col = _xlsx_column_index(ref)
            if col < 0:
                continue
            values[col] = _xlsx_cell_text(cell, shared, ns)
        if values:
            width = max(values) + 1
            rows.append([values.get(i, "") for i in range(width)])
    return rows


def _xlsx_column_index(ref: str) -> int:
    letters = "".join(ch for ch in ref if ch.isalpha()).upper()
    if not letters:
        return -1
    value = 0
    for ch in letters:
        value = value * 26 + (ord(ch) - ord("A") + 1)
    return value - 1


def _xlsx_cell_text(cell: ET.Element, shared: list[str], ns: dict[str, str]) -> str:
    kind = cell.attrib.get("t")
    if kind == "inlineStr":
        return "".join(node.text or "" for node in cell.findall(".//x:is//x:t", ns))
    value = cell.find("x:v", ns)
    text = "" if value is None or value.text is None else value.text
    if kind == "s":
        try:
            return shared[int(text)]
        except (ValueError, IndexError):
            return ""
    return text


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
        if path.suffix.lower() in (".xlsx", ".xlsm"):
            return cls(cls._from_xlsx(path), path)
        if path.suffix.lower() in (".sqlite", ".db", ".sqlite3"):
            return cls(cls._from_sqlite(path), path)
        raise AuditError(f"pricebook-unsupported-format:{path.suffix}")

    @staticmethod
    def _from_csv(path: Path) -> list[ReferenceRow]:
        rows: list[ReferenceRow] = []
        with open(path, newline="") as f:
            for rec in csv.DictReader(f):
                keys = {_header_key(k): (v or "").strip() for k, v in rec.items()}
                try:
                    rows.append(ReferenceRow(
                        sku=_field(keys, "sku"),
                        description=_field(keys, "description"),
                        unit_price=float(_field(keys, "unit_price")),
                    ))
                except ValueError as e:
                    raise AuditError(f"pricebook-bad-row:{rec}") from e
        return rows

    @staticmethod
    def _from_xlsx(path: Path) -> list[ReferenceRow]:
        """Read the first worksheet of a modern Excel workbook.

        The expected business shape is the same as CSV: columns for SKU/part,
        description, and unit price. This intentionally avoids a heavyweight
        dependency so the Windows demo keeps working offline.
        """
        rows: list[ReferenceRow] = []
        try:
            with zipfile.ZipFile(path) as zf:
                shared = _xlsx_shared_strings(zf)
                sheet_names = sorted(
                    name for name in zf.namelist()
                    if name.startswith("xl/worksheets/sheet") and name.endswith(".xml")
                )
                if not sheet_names:
                    raise AuditError(f"pricebook-xlsx-no-worksheets:{path.name}")
                matrix = _xlsx_sheet_matrix(zf.read(sheet_names[0]), shared)
        except zipfile.BadZipFile as e:
            raise AuditError(f"pricebook-xlsx-invalid:{path.name}") from e

        matrix = [row for row in matrix if any(cell.strip() for cell in row)]
        if not matrix:
            return rows
        header = [_header_key(cell) for cell in matrix[0]]
        for row in matrix[1:]:
            keys = {
                header[i]: (row[i].strip() if i < len(row) else "")
                for i in range(len(header))
                if header[i]
            }
            if not any(keys.values()):
                continue
            try:
                rows.append(ReferenceRow(
                    sku=_field(keys, "sku"),
                    description=_field(keys, "description"),
                    unit_price=float(_field(keys, "unit_price").replace("$", "").replace(",", "")),
                ))
            except ValueError as e:
                raise AuditError(f"pricebook-bad-row:{keys}") from e
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
