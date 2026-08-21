"""Savings / value story — "here's what our system caught for you."

Every number here is derived DETERMINISTICALLY from a signed receipt's own
totals and review queue. Nothing is estimated or modelled: the money "caught"
is exactly the exposure the deterministic checks already flagged (price-history
overcharge + industry-benchmark overpay + taught-policy overage), and the
"things you'd have missed" are the items the pipeline surfaced that a person
would otherwise never have looked at (no price history, no industry benchmark,
ungrounded numbers, data-quality gaps). The follow-up list is the review queue
itself — the things to schedule so nothing slips.
"""
from __future__ import annotations

# Review-queue kinds that represent money we flagged as recoverable/at-risk.
_HISTORY_KINDS = {"overcharge-flag"}
_MARKET_KINDS = {"market-overcharge-flag"}
_POLICY_KINDS = {"floor-veto"}
# Kinds that represent "you'd have missed this" surfacing (not a dollar figure).
_SURFACED_KINDS = {
    "no-reference": "noPriceHistory",
    "market-no-reference": "noIndustryBenchmark",
    "ungrounded": "ungrounded",
    "weak-grounding": "ungrounded",
}


def savings_report(receipt: dict) -> dict:
    totals = receipt.get("totals", {})
    queue = receipt.get("reviewQueue", [])

    history_usd = float(totals.get("potentialOverchargeUSD", 0.0) or 0.0)
    market_usd = float(totals.get("marketOverchargeUSD", 0.0) or 0.0)
    policy_usd = float(totals.get("policyOverageUSD", 0.0) or 0.0)
    # HARD RULE — no ML touches the banked number. The banked money figure comes
    # ONLY from DETERMINISTIC-FACT sources: the customer's OWN price history and
    # the taught policy floor (symbolic/Jeeves). The kist-researched industry
    # benchmark is ML-RETRIEVED — a librarian, not a judge — so it is surfaced as
    # a REVIEW SIGNAL beside the number and is NEVER banked into it.
    money_caught = round(history_usd + policy_usd, 2)

    surfaced = {"noPriceHistory": 0, "noIndustryBenchmark": 0,
                "ungrounded": 0, "dataQuality": 0}
    counts_by_kind: dict[str, int] = {}
    follow_ups: list[dict] = []
    for item in queue:
        kind = item.get("kind", "")
        counts_by_kind[kind] = counts_by_kind.get(kind, 0) + 1
        if kind in _SURFACED_KINDS:
            surfaced[_SURFACED_KINDS[kind]] += 1
        if kind.startswith("data-quality") or item.get("category") == "data-quality":
            surfaced["dataQuality"] += 1
        follow_ups.append({
            "kind": kind,
            "invoice": item.get("invoice", ""),
            "line": item.get("line"),
            "detail": item.get("detail", ""),
            "priority": _priority(kind),
        })
    surfaced["dataQuality"] = int(totals.get("dataQualityIssues", surfaced["dataQuality"]) or 0)
    surfaced["total"] = (surfaced["noPriceHistory"] + surfaced["noIndustryBenchmark"]
                         + surfaced["ungrounded"] + surfaced["dataQuality"])

    follow_ups.sort(key=lambda f: (-f["priority"], f["invoice"]))

    return {
        "invoices": int(totals.get("invoices", 0) or 0),
        "linesChecked": int(totals.get("linesChecked", 0) or 0),
        "flagsFound": int(totals.get("flagged", len(queue)) or 0),
        "moneyCaughtUSD": money_caught,  # deterministic-only (own history + policy)
        # ML-retrieved industry overpay — reported for review, NEVER banked above.
        "industryReviewSignalUSD": round(market_usd, 2),
        "industryReviewSource": "kist-researched (ML) — review only, not banked",
        "breakdown": {
            "priceHistoryUSD": round(history_usd, 2),
            "industryBenchmarkUSD": round(market_usd, 2),
            "policyUSD": round(policy_usd, 2),
        },
        "itemsSurfaced": surfaced,
        "countsByKind": counts_by_kind,
        "followUps": follow_ups,
        "headline": _headline(receipt, money_caught, market_usd, surfaced),
    }


def _priority(kind: str) -> int:
    if kind in _MARKET_KINDS or kind in _HISTORY_KINDS or kind in _POLICY_KINDS:
        return 3
    if kind in ("ungrounded", "arithmetic-mismatch"):
        return 2
    return 1


def _headline(receipt: dict, money_caught: float, market_usd: float,
              surfaced: dict) -> str:
    totals = receipt.get("totals", {})
    invoices = int(totals.get("invoices", 0) or 0)
    flagged = int(totals.get("flagged", 0) or 0)
    if flagged == 0:
        return (f"Reviewed {invoices} invoice(s) and found nothing to recover — "
                "clean, and now proven with a signed receipt.")
    parts = [f"Found {flagged} issue(s) across {invoices} invoice(s) — "
             f"${money_caught:,.2f} in deterministic, sourced overpay exposure"]
    if market_usd > 0:
        parts.append(f"plus ${market_usd:,.2f} flagged above industry pricing to "
                     "review (kist-researched estimate — not banked)")
    missed = surfaced.get("total", 0)
    if missed > 0:
        parts.append(f"and surfaced {missed} item(s) you'd otherwise have missed")
    return " — ".join(parts) + "."


def savings_text(receipt: dict) -> str:
    r = savings_report(receipt)
    b = r["breakdown"]
    lines = [
        r["headline"],
        "",
        f"Banked overpay exposure (deterministic, sourced): ${r['moneyCaughtUSD']:,.2f}",
        f"  • Price-history overcharge : ${b['priceHistoryUSD']:,.2f}",
        f"  • Policy overage           : ${b['policyUSD']:,.2f}",
        f"Review signal (kist-researched, NOT banked): ${r['industryReviewSignalUSD']:,.2f}",
        f"  • Above industry benchmark : ${b['industryBenchmarkUSD']:,.2f}",
        f"Flags found: {r['flagsFound']}   Lines checked: {r['linesChecked']}",
        f"Items you'd have missed: {r['itemsSurfaced']['total']}",
    ]
    if r["followUps"]:
        lines.append("")
        lines.append("Follow-ups to schedule (nothing slips):")
        for f in r["followUps"][:10]:
            lines.append(f"  [{f['kind']}] {f['invoice']} line={f.get('line')} — {f['detail']}")
    return "\n".join(lines)
