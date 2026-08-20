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
scan ─▶ ocr.py ─▶ layout.py ─▶ validate.py ─▶ grounding.py ─▶ floor.py ─┐
(PNG)   (Apple    (determin-   (qty×unit==    (trace every    (human-    │
        Vision,    istic table  total, sum     number to      taught      ├▶ audit.py
        on-device  reconstruct) == stated)     clean pixels   rules       │  (human
        / Tessd)                               + witness or    VETO)       │   gate)
                                               FAIL CLOSED)                │
                                                                          ▼
                                                        signed receipt .json (receipt.py, Ed25519)
                                                                          │
                                                                          ▼
category map ─▶ SQLite store ─▶ analyst / CSV export / HTML report / Slack payload
               (Jeeves/PREL-
                style claims)
```

- **Deterministic where it matters.** OCR is probabilistic; *everything after
  is not*. Column layout is anchored to the invoice's own headers; the
  arithmetic gate re-derives every total; the price check is the customer's
  median historical price. A model never decides whether you were overcharged.
- **The number pipeline never emits a hallucinated number** (`grounding.py`).
  The arithmetic gate catches an *inconsistent* line; grounding catches the
  harder case — a line OCR misread into a *self-consistent wrong* triple. Every
  money number must trace to a single clean, high-confidence OCR token **and**
  carry an independent witness (price history, or the invoice's own grand total
  reconciles). Verdicts, borrowing Peel's `resolve` vocabulary:
  `grounded` (trust it) · `needs-review` (readable but weak — human) ·
  `ungrounded` (unreadable — **fail closed, never emitted**).
- **Symbolic floor — a real veto the price history can't have** (`floor.py`).
  Human-taught vendor/domain rules (`max_unit_price`, `qty_integer`, …) veto a
  line the arithmetic + price checks would wave through. It implements the
  Perslis **Jeeves contract** (`teach_relation` + `check_contradiction`) for the
  invoice domain, fail-closed: known relation-types only, mandatory
  source+evidence, refused on conflict, idempotent. Grounding answers "did we
  read it right?"; the floor answers "is it *allowed*?" — two failure modes,
  kept separate. (The live Perslis/COBOL Jeeves floor abstains `unknown` on
  invoice claims, so wiring it directly would be a veto that never fires — the
  rules live here instead; the contract matches so it can delegate later.)
- **Fail-closed, named reasons.** No headers → `layout-no-table-headers`. No
  history → `no-reference`. Garbled total → stays `None` (never invented).
  Nothing degrades quietly.
- **Human gate is structural.** `audit.py` puts every flag in a review queue;
  it approves and rejects nothing.
- **What happens after extraction:** `categories.py` maps every invoice and
  every line item into an auditable category claim; `store.py` persists the
  signed receipt into SQL; `analytics.py` turns that into category/vendor spend,
  price exposure, policy exposure, CSVs, a visual report, and a Slack-ready
  payload. SQL + claims are the source of truth; exports are derived views.

## Use

```bash
scripts/build.sh                       # compile the on-device OCR binary (macOS)
python3 -m invoice_audit audit <scans-dir> --pricebook <history.csv|.sqlite> \
                                          [--floor <rules.json>]
python3 -m invoice_audit audit-db <scans-dir> --pricebook <history.csv|.sqlite> \
                                             --db business.sqlite \
                                             [--floor <rules.json>]
python3 -m invoice_audit findings --db business.sqlite
python3 -m invoice_audit ask --db business.sqlite "show overcharges"
python3 -m invoice_audit analytics --db business.sqlite
python3 -m invoice_audit export --db business.sqlite --out exports/
python3 -m invoice_audit report --db business.sqlite --out business-report.html
python3 -m invoice_audit slack-payload --db business.sqlite --out slack.json
python3 -m invoice_audit email-draft --db business.sqlite --out boss-summary.eml \
                                     --attach-report business-report.html
python3 -m invoice_audit integration-payload --db business.sqlite --out api.json
python3 -m invoice_audit send-webhook --db business.sqlite --url <zapier-hook-url>
python3 -m invoice_audit watch <scans-dir> --pricebook <history.csv|.sqlite> \
                                           --db business.sqlite [--once]
python3 -m invoice_audit verify <receipt.json>   # re-check signature + input hashes
```

- **Price history:** CSV (`sku,description,unit_price,date`) or SQLite (a
  `price_history(sku,description,unit_price)` table) — the shapes the kist
  Data-Exchange engine already exports.
- **Taught rules (`--floor`):** JSON, schema `invoice-audit.floor.v1`; each rule
  carries `source` + `evidence` and is hashed into the receipt.
- **PDFs:** accepted directly. Each page is rendered to a cached OCR image under
  `.invoice-audit-rendered/`, while the receipt keeps the original PDF
  path/hash/page for verification.
- **SQLite backend:** `audit-db` writes the signed receipt into queryable tables
  for source files, invoices, line items, findings, categories, policy exposure,
  and PREL/Jeeves-style business claims. `ask` answers from those tables with
  invoice/line citations.
- **Business outputs:** `analytics` prints the category/vendor exposure map;
  `export` writes CSVs for finance/ops; `report` writes a standalone visual HTML
  report; `slack-payload` writes a safe JSON message but does not post anywhere
  until a webhook is explicitly configured.
- **Share/connect outputs:** `email-draft` writes a boss-ready `.eml` with the
  executive summary and optional attached HTML report; `integration-payload`
  writes generic API/Zapier JSON; `send-webhook` posts that JSON only when a
  webhook URL is explicitly supplied.
- **Revenue/profit boundary:** this database currently proves AP invoice spend,
  discrepancy exposure, vendors, categories, OCR evidence, and policy leaks. To
  answer “where are we making the most money,” connect sales, work orders,
  production output, GL revenue, or job-cost data next.
- **Continuous worker:** `watch` fingerprints the invoice/PDF folder, pricebook,
  and rules file; when inputs change it reruns the audit and updates the SQLite
  backend. `--once` performs one check for schedulers/launch agents.

## Native Demo Apps

For a non-terminal demo, launch the small native shell:

```bash
scripts/run_swift_app.sh
scripts/build_swift_app.sh              # creates dist/Invoice Audit.app
```

The SwiftUI app opens directly into the audit workspace: choose invoice/PDF
sources, choose a price-history CSV/SQLite file, run the audit, inspect the
scan plus OCR-to-digital conversion, review flagged findings, verify the
receipt, ask the SQL-backed business analyst follow-up questions, open the
visual business report, generate a boss-ready email draft, export an API file,
or paste a Zapier/webhook URL and send the business report JSON.

On Windows 11, use the native launcher:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_windows_native.ps1 -Setup
powershell -ExecutionPolicy Bypass -File scripts\run_windows_native.ps1
```

That shell uses native Windows controls and the same Tesseract-backed OCR path
as `scripts\run_windows.ps1`, with the same report, email draft, API file, and
Zapier/webhook send actions.

## Demo (real OCR, planted cases)

```bash
python3 demo/make_fixtures.py          # renders 3 invoice PNGs + a pricebook
python3 -m invoice_audit audit demo/scans --pricebook demo/pricebook.csv \
                                          --floor demo/floor-rules.json
```

Catches: the ~$6,000 hydraulic-pump overcharge (price history), an arithmetic
error, an untethered number (grounding), and — the one the pricebook is *blind*
to — a proximity sensor with no purchase history, caught only because a human
taught a `$60` ceiling (`floor-veto`, `policyOverageUSD`). Emits a receipt that
survives `verify` and fails the instant a scan / pricebook / rules byte changes.

> Live behavior worth seeing: on invoice-30073 Apple Vision misreads the grand
> total's "TOTAL" label as garbage. The engine does **not** invent a total from
> it — it stays `None`, the sensor line drops to `needs-review`, and the floor
> still vetoes it. OCR degraded; nothing was hallucinated. That is the point.

## Status — PILOT-READY

Happy path proven end-to-end on real (rendered) scans and PDF-rendered pages;
fail-closed on the error paths; **43/43 tests green** (each stage + the
grounding ladder + every floor outcome pinned per-site); receipts sign / verify
/ tamper-detect over scans, original PDFs, pricebook, **and** the taught-rules
file.

**Enterprise-blocked — named gaps (do not claim these work):**
- **Residual hallucination:** a *high-confidence, self-consistent* OCR misread
  that also carries a witness can still pass. Closing it needs a **second
  independent read** (digit-for-digit agreement across two OCR engines) — the
  next brick, not this one. The macOS-Vision + Windows-Tesseract split below is
  the natural place to add it (two engines = the second read).
- **Deep-legacy price history** (trapped in an app with no export) uses the
  Perslis VM+OCR screen-read path — real but not wired into this engine yet.
- **Inbound connectors beyond local files** (ERP APIs, email inboxes, network
  shares, app databases) are not wired yet. Current sources are local PDFs/images
  plus CSV/SQLite price history. Outbound sharing is available through email
  draft, CSV/report export, and generic webhook JSON.
- **Layout coverage:** tuned for standard QTY/DESC/UNIT/TOTAL tables; odd vendor
  layouts and OCR-garbled headers/totals fail closed, they don't guess.
- Not integrated with the kist approval loop / remote-session model yet.

## Cross-platform (macOS + Windows 11)

The pipeline is pure Python with Ed25519 receipt signing (`cryptography` when
available, a pinned RFC 8032 fallback otherwise); only the **OCR token source**
is OS-specific — the designed seam. macOS uses the on-device Apple Vision binary
(`src/vision_ocr.swift`); Windows 11 uses Tesseract (chosen because it emits
per-word **confidence**, which the grounding layer requires — Windows.Media.Ocr
does not). Both emit the same `{text,confidence,x,y,w,h}` token JSON, so layout
→ validate → grounding → floor → receipt are byte-for-byte identical. See
`ocr.py` (backend selection) and `scripts/` for the Windows run path.

Validated on Windows 11 ARM64 with Python 3.12.10 and Tesseract 5.4.0: the
current fixture audit, signature verification, and the same test suite pass. The
Windows-signed receipt also verifies with `cryptography` on macOS.

Signing keys: `~/.invoice-audit/signing.key` (0600, generated on first run).
