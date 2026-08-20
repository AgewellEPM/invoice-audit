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

## Use

```bash
scripts/build.sh                       # compile the on-device OCR binary (macOS)
python3 -m invoice_audit audit <scans-dir> --pricebook <history.csv|.sqlite> \
                                          [--floor <rules.json>]
python3 -m invoice_audit verify <receipt.json>   # re-check signature + input hashes
```

- **Price history:** CSV (`sku,description,unit_price,date`) or SQLite (a
  `price_history(sku,description,unit_price)` table) — the shapes the kist
  Data-Exchange engine already exports.
- **Taught rules (`--floor`):** JSON, schema `invoice-audit.floor.v1`; each rule
  carries `source` + `evidence` and is hashed into the receipt.

## Native Demo Apps

For a non-terminal demo, launch the small native shell:

```bash
scripts/run_swift_app.sh
scripts/build_swift_app.sh              # creates dist/Invoice Audit.app
```

The SwiftUI app opens directly into the audit workspace: run the demo audit,
inspect invoice images, review flagged findings, verify the receipt, and reveal
the signed JSON artifact. It is intentionally thin; all results still come from
the same Python engine and signed receipt path.

On Windows 11, use the native launcher:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_windows_native.ps1 -Setup
powershell -ExecutionPolicy Bypass -File scripts\run_windows_native.ps1
```

That shell uses native Windows controls and the same Tesseract-backed OCR path
as `scripts\run_windows.ps1`.

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

Happy path proven end-to-end on real (rendered) scans; fail-closed on the error
paths; **33/33 tests green** (each stage + the grounding ladder + every floor
outcome pinned per-site); receipts sign / verify / tamper-detect over scans,
pricebook, **and** the taught-rules file.

**Enterprise-blocked — named gaps (do not claim these work):**
- **Residual hallucination:** a *high-confidence, self-consistent* OCR misread
  that also carries a witness can still pass. Closing it needs a **second
  independent read** (digit-for-digit agreement across two OCR engines) — the
  next brick, not this one. The macOS-Vision + Windows-Tesseract split below is
  the natural place to add it (two engines = the second read).
- **PDF ingest** not wired — render to PNG first (`pdf-not-wired`).
- **Deep-legacy price history** (trapped in an app with no export) uses the
  Perslis VM+OCR screen-read path — real but not wired into this engine yet.
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
current fixture audit, signature verification, and all 33 tests pass. The
Windows-signed receipt also verifies with `cryptography` on macOS.

Signing keys: `~/.invoice-audit/signing.key` (0600, generated on first run).
