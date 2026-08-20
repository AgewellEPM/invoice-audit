# CLAUDE.md — invoice-audit

Project rules. These extend the global rules; where they conflict, these win.

## What this is
Verified vendor-invoice auditing with signed receipts. The United Concrete
demo. Thesis: **OCR is the only probabilistic step; every money decision after
it is deterministic, traceable, and fail-closed.** Proof (a signed, re-runnable
receipt) is the product.

## Target bar
Build to **ENTERPRISE-READY**; **label down to the truth**. Today the honest
label is **PILOT-READY** — see README "Status" for the exact enterprise-blocking
gaps. Never label a tier that isn't earned. Never report a number "verified" on
an inconclusive OCR result.

## Non-negotiables
1. **Determinism after OCR.** No model decides money. If you add an LLM, it goes
   *before* the arithmetic/grounding gates, never instead of them.
2. **Fail closed, named reasons.** Every failure is a machine-readable reason
   code (`layout-no-table-headers`, `no-reference`, `ungrounded`, `floor-*`).
   Nothing degrades silently; nothing is invented from garbled OCR.
3. **Human gate is structural.** `audit.py` approves/rejects nothing — every
   flag goes to the review queue.
4. **The receipt is the contract.** Anything that affects a verdict (scans,
   pricebook, taught rules) is hashed into the receipt and re-checked by
   `verify`. Bump the schema version on any receipt shape change.
5. **Symbolic = real, never theater.** The floor only vetoes on rules a human
   actually taught (mandatory source+evidence). Do NOT wire a symbolic engine
   that abstains and dress it as a check.
6. **One responsibility per module.** ocr / layout / validate / grounding /
   floor / pricebook / receipt / audit stay separate. Keep files well under 1k
   lines (all are tiny — keep them that way).

## Multi-site test discipline
This engine has parallel "surfaces" (every grounding verdict, every floor
relation-type, every input hashed into the receipt). A regression test pins the
**invariant on each surface by name**, not just the one bug. See
`tests/test_invoice_audit.py` — grounding has one test per verdict; the floor
has one per outcome (veto / consistent / unknown / each refusal); verify has one
per hashed input. Extend in that shape.

## Verify before "done"
- `python3 tests/test_invoice_audit.py` (or `pytest tests/ -q`) — must be all
  green. Real OCR runs through real rendered scans; the demo never feeds text
  straight to the parser.
- `python3 -m invoice_audit audit demo/scans --pricebook demo/pricebook.csv
  --floor demo/floor-rules.json` then `verify` the receipt — must say VERIFIED.
- Codex review gate before returning control (global rule).

## Cross-platform
Only OCR is OS-specific. macOS = Apple Vision (`src/vision_ocr.swift`);
Windows 11 = Tesseract (it emits per-word confidence, which grounding needs).
Both emit the same token JSON; the rest of the pipeline is identical. When
touching `ocr.py`, keep the backend contract `{text,confidence,x,y,w,h}` stable
— it is the seam the whole pipeline depends on.
