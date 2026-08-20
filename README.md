# invoice-audit — verified vendor-invoice auditing with signed receipts

Drop a folder of scanned vendor invoices + the customer's own price history.
Out comes: every line item extracted, checked against what they actually paid
before, every suspicious charge flagged for a human — and a **signed,
re-runnable receipt** of exactly what was checked, against what, with what
verdict.

Built for the United Concrete "$6,000 forklift invoice" problem: catch the
overcharge automatically, but **never** auto-approve or auto-reject money —
that always goes to a person. Proof is the product.

## The pipeline (one responsibility per module)

```
scan (PNG) ─▶ ocr.py ─▶ layout.py ─▶ validate.py ─┐
 vision-ocr   (Apple    (determin-   (qty×unit==   │
 Swift/       Vision,    istic table  total, sum   ├▶ audit.py ─▶ signed
 on-device)   on-device) reconstruct) == stated)   │   (human      receipt
                                     pricebook.py ──┘    gate)      .json
                                     (their history
                                      = the truth)                receipt.py
                                                                  (Ed25519)
```

- **Deterministic where it matters.** OCR is probabilistic; everything after
  is not. Column layout is anchored to the invoice's own headers; the
  arithmetic gate re-derives every total; the price check is the customer's
  median historical price. A model never decides whether you were overcharged.
- **Fail-closed, named reasons.** No table headers → `layout-no-table-headers`.
  No history for a part → `no-reference` (human review), never a silent pass.
  Low OCR confidence on a line → `low-confidence`. Nothing degrades quietly.
- **Human gate is structural.** `audit.py` puts every flag in a review queue;
  it approves and rejects nothing.

## Use

```bash
scripts/build.sh                       # compile the on-device OCR binary
python3 -m invoice_audit audit <scans-dir> --pricebook <history.csv|.sqlite>
python3 -m invoice_audit verify <receipt.json>     # re-check signature + input hashes
```

Price history: CSV (`sku,description,unit_price,date`) or SQLite (a
`price_history(sku,description,unit_price)` table) — the shapes the kist
Data-Exchange engine already exports.

## Demo (real OCR, planted cases)

```bash
python3 demo/make_fixtures.py          # renders 3 invoice PNGs + a pricebook
python3 -m invoice_audit audit demo/scans --pricebook demo/pricebook.csv
```
Catches the ~$6,000 hydraulic-pump overcharge, an arithmetic error, and an
item with no purchase history — and emits a receipt that survives
`verify` and fails the instant a scan byte is altered.

## Status — PILOT-READY

Happy path proven end-to-end on real (rendered) scans, fail-closed on the
error paths, 10/10 tests green, receipts sign/verify/tamper-detect.

**Enterprise-blocked — named gaps (do not claim these work):**
- **PDF ingest** not wired — render to PNG first (fails closed:
  `pdf-not-wired`). Needs a PDF→image stage.
- **Deep-legacy price history** (data trapped in an app with no export) uses
  the Perslis VM+OCR screen-read path — real but not wired into this engine
  yet; today the pricebook must be a file/DB.
- **Layout coverage:** tuned for standard QTY/DESC/UNIT/TOTAL tables. Odd
  vendor layouts need per-format handling (fails closed, doesn't guess).
- **No live LLM assist** in the extraction path (deliberate for v1 — keeps it
  deterministic + offline). A model could later help messy descriptions,
  behind the same arithmetic gate.
- Not integrated with the kist approval loop / remote-session model yet.

Signing keys: `~/.invoice-audit/signing.key` (0600, generated on first run).
