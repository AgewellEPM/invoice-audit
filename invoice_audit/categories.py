"""Deterministic invoice category mapping.

The category layer is deliberately simple and auditable: SKU prefix, vendor,
and description keyword rules produce evidence that can be stored as
Jeeves/PREL-style claims. A learned classifier can suggest future rules, but
the pilot needs explainable labels that survive review.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class CategoryRule:
    category: str
    sku_prefixes: tuple[str, ...] = ()
    vendor_keywords: tuple[str, ...] = ()
    item_keywords: tuple[str, ...] = ()


CATEGORY_RULES: tuple[CategoryRule, ...] = (
    CategoryRule(
        "Hydraulics",
        sku_prefixes=("HYD",),
        vendor_keywords=("HYDRAULIC", "HYDRAULICS"),
        item_keywords=("HYDRAULIC", "PUMP", "HOSE", "CYLINDER"),
    ),
    CategoryRule(
        "Forklift & Material Handling",
        sku_prefixes=("FLT",),
        vendor_keywords=("FORKLIFT", "LIFT TRUCK"),
        item_keywords=("FORKLIFT", "BRAKE KIT", "MAST", "LIFT"),
    ),
    CategoryRule(
        "Sensors & Controls",
        sku_prefixes=("SEN", "CTRL", "PLC"),
        vendor_keywords=("SENSOR", "CONTROLS", "AUTOMATION"),
        item_keywords=("SENSOR", "PROXIMITY", "CONTROL", "PLC"),
    ),
    CategoryRule(
        "Form Oil & Release Agents",
        sku_prefixes=("OIL",),
        item_keywords=("FORM OIL", "RELEASE AGENT", "DRUM"),
    ),
    CategoryRule(
        "Rebar & Steel",
        sku_prefixes=("RBR", "STL"),
        item_keywords=("REBAR", "STEEL", "BUNDLE"),
    ),
    CategoryRule(
        "Cement & Aggregates",
        sku_prefixes=("CEM", "AGG", "SND", "GRV"),
        vendor_keywords=("CONCRETE", "CEMENT", "AGGREGATE"),
        item_keywords=("CEMENT", "PORTLAND", "AGGREGATE", "SAND", "GRAVEL"),
    ),
)

UNCATEGORIZED = "Uncategorized"


def classify_item(
    sku: str | None,
    description: str | None,
    vendor: str | None = None,
) -> dict:
    sku_text = (sku or "").upper().strip()
    desc_text = (description or "").upper().strip()
    vendor_text = (vendor or "").upper().strip()
    joined = " ".join(part for part in (sku_text, desc_text, vendor_text) if part)

    for rule in CATEGORY_RULES:
        for prefix in rule.sku_prefixes:
            if sku_text.startswith(prefix):
                return _result(rule.category, "sku_prefix", prefix)

    for rule in CATEGORY_RULES:
        for keyword in rule.item_keywords:
            if keyword in desc_text:
                return _result(rule.category, "item_keyword", keyword)

    for rule in CATEGORY_RULES:
        for keyword in rule.vendor_keywords:
            if keyword in vendor_text:
                return _result(rule.category, "vendor_keyword", keyword)

    return {
        "category": UNCATEGORIZED,
        "basis": "fallback",
        "matched": "",
        "confidence": 0.25,
        "explanation": "No category rule matched SKU, description, or vendor.",
    }


def classify_invoice(vendor: str | None, lines: Iterable[dict]) -> dict:
    spend_by_category: dict[str, float] = defaultdict(float)
    evidence: list[dict] = []
    for line in lines:
        cat = line.get("category")
        cat_ev = line.get("categoryEvidence") or {}
        if not cat:
            cat_ev = classify_item(
                str(line.get("sku", "")),
                str(line.get("description", "")),
                vendor,
            )
            cat = cat_ev["category"]
        spend_by_category[str(cat)] += float(line.get("line_total", 0) or 0)
        evidence.append({
            "sku": line.get("sku", ""),
            "category": cat,
            "basis": cat_ev.get("basis", "line"),
            "matched": cat_ev.get("matched", ""),
        })

    if spend_by_category:
        category = max(spend_by_category.items(), key=lambda item: item[1])[0]
        total = sum(spend_by_category.values())
        share = spend_by_category[category] / total if total else 0.0
        vendor_guess = classify_item("", "", vendor)
        if share < 0.60 and vendor_guess["category"] != UNCATEGORIZED:
            vendor_guess = dict(vendor_guess)
            vendor_guess.update({
                "basis": "invoice_vendor_keyword",
                "confidence": 0.75,
                "lineEvidence": evidence,
                "explanation": (
                    f"Line spend is split across categories; vendor evidence "
                    f"maps invoice to {vendor_guess['category']}."
                ),
            })
            return vendor_guess
        return {
            "category": category,
            "basis": "dominant_line_spend",
            "matched": category,
            "confidence": round(max(0.60, share), 3),
            "explanation": (
                f"{category} has the largest share of invoice line spend "
                f"({share:.0%})."
            ),
            "lineEvidence": evidence,
        }

    vendor_guess = classify_item("", "", vendor)
    vendor_guess["basis"] = f"invoice_{vendor_guess['basis']}"
    return vendor_guess


def _result(category: str, basis: str, matched: str) -> dict:
    return {
        "category": category,
        "basis": basis,
        "matched": matched,
        "confidence": 0.95,
        "explanation": f"Matched {basis.replace('_', ' ')} '{matched}'.",
    }
