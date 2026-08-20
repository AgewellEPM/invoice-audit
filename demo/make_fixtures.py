"""Render synthetic vendor invoices as PNG scans + a price-history CSV.

These are REAL images that go through REAL OCR — the demo never feeds text
straight to the parser. Planted cases:
  - INV 30071 (Hartford Hydraulics): HYD-PUMP at $5,980 vs $2,950 history —
    the "$6,000 forklift invoice" story, must flag overcharge.
  - INV 30072 (Nutmeg Concrete Supply): clean, all at history prices.
  - INV 30073 (Yankee Forklift Parts): one arithmetic error (qty x unit !=
    total) and one item with no purchase history (both must flag).
"""
from __future__ import annotations

import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
SCANS = HERE / "scans"
FONT = "/System/Library/Fonts/Menlo.ttc"

PRICE_HISTORY = [
    # sku, description, unit_price, date
    ("HYD-4410", "HYDRAULIC PUMP ASSY", 2950.00, "2026-03-11"),
    ("HYD-4410", "HYDRAULIC PUMP ASSY", 2895.00, "2025-11-02"),
    ("HYD-4410", "HYDRAULIC PUMP ASSY", 3010.00, "2025-04-19"),
    ("FLT-2200", "FORKLIFT BRAKE KIT", 412.50, "2026-01-27"),
    ("FLT-2200", "FORKLIFT BRAKE KIT", 399.00, "2025-08-14"),
    ("OIL-0055", "FORM OIL 55 GAL DRUM", 289.00, "2026-05-02"),
    ("OIL-0055", "FORM OIL 55 GAL DRUM", 275.00, "2025-12-09"),
    ("RBR-0620", "REBAR #6 20FT BUNDLE", 184.00, "2026-06-30"),
    ("RBR-0620", "REBAR #6 20FT BUNDLE", 179.50, "2026-02-12"),
    ("CEM-0094", "PORTLAND CEMENT T-I/II PALLET", 612.00, "2026-04-21"),
]

INVOICES = [
    {
        "file": "invoice-30071.png",
        "vendor": "HARTFORD HYDRAULICS INC",
        "no": "30071", "date": "08/12/2026",
        "lines": [
            # THE PLANT: pump at ~2x history → overcharge-flag
            ("HYD-4410", "HYDRAULIC PUMP ASSY", 2, 5980.00),
            ("FLT-2200", "FORKLIFT BRAKE KIT", 1, 415.00),
        ],
    },
    {
        "file": "invoice-30072.png",
        "vendor": "NUTMEG CONCRETE SUPPLY",
        "no": "30072", "date": "08/14/2026",
        "lines": [
            ("OIL-0055", "FORM OIL 55 GAL DRUM", 4, 291.00),
            ("RBR-0620", "REBAR #6 20FT BUNDLE", 10, 186.00),
            ("CEM-0094", "PORTLAND CEMENT T-I/II PALLET", 3, 618.00),
        ],
    },
    {
        "file": "invoice-30073.png",
        "vendor": "YANKEE FORKLIFT PARTS CO",
        "no": "30073", "date": "08/17/2026",
        "lines": [
            # arithmetic error: total printed as 1279.00, but 2 x 412.50 = 825.00
            ("FLT-2200", "FORKLIFT BRAKE KIT", 2, 412.50, 1279.00),
            # no purchase history → no-reference flag
            ("SEN-7781", "PROXIMITY SENSOR HD", 6, 88.00),
        ],
    },
]


def render(inv: dict) -> None:
    W, H = 1400, 1000
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    big = ImageFont.truetype(FONT, 40)
    med = ImageFont.truetype(FONT, 28)

    d.text((60, 50), inv["vendor"], fill="black", font=big)
    d.text((60, 120), f"INVOICE {inv['no']}    DATE {inv['date']}",
           fill="black", font=med)

    cols = {"qty": 60, "desc": 220, "unit": 900, "total": 1150}
    y = 240
    d.text((cols["qty"], y), "QTY", fill="black", font=med)
    d.text((cols["desc"], y), "DESCRIPTION", fill="black", font=med)
    d.text((cols["unit"], y), "UNIT", fill="black", font=med)
    d.text((cols["total"], y), "TOTAL", fill="black", font=med)
    d.line((60, y + 45, W - 60, y + 45), fill="black", width=2)

    grand = 0.0
    y += 80
    for line in inv["lines"]:
        sku, desc, qty, unit = line[:4]
        total = line[4] if len(line) > 4 else round(qty * unit, 2)
        grand += total
        d.text((cols["qty"], y), str(qty), fill="black", font=med)
        d.text((cols["desc"], y), f"{sku} {desc}", fill="black", font=med)
        d.text((cols["unit"], y), f"${unit:,.2f}", fill="black", font=med)
        d.text((cols["total"], y), f"${total:,.2f}", fill="black", font=med)
        y += 70

    d.line((60, y + 10, W - 60, y + 10), fill="black", width=2)
    d.text((cols["unit"], y + 40), "TOTAL", fill="black", font=med)
    d.text((cols["total"], y + 40), f"${grand:,.2f}", fill="black", font=med)

    SCANS.mkdir(exist_ok=True)
    img.save(SCANS / inv["file"])


def main() -> None:
    for inv in INVOICES:
        render(inv)
    with open(HERE / "pricebook.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["sku", "description", "unit_price", "date"])
        for row in PRICE_HISTORY:
            w.writerow(row)
    print(f"rendered {len(INVOICES)} scans -> {SCANS}")
    print(f"pricebook -> {HERE / 'pricebook.csv'}")


if __name__ == "__main__":
    main()
