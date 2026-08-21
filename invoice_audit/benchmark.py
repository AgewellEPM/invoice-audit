"""Market-benchmark cache — kist research in, PriceBook-shaped CSV out.

This is the bridge between the probabilistic research (`kist_bridge`) and the
deterministic overpay check (`pricebook.PriceBook`). It:

  1. Researches a fair-market unit price per item via kist (cross-model).
  2. Writes `market-pricebook.csv` in the SAME shape the auditor already
     consumes (`sku,description,unit_price`) — so `audit --market` flags
     `market-overcharge-flag` with ZERO new money logic.
  3. Writes a `market-benchmarks.json` provenance sidecar (low/median/high,
     confidence, models, sources, as-of, live-vs-fixture) so the research is
     auditable and can be hashed into the receipt.

Two paths, per Luke's choice:
  * `refresh_all(...)`  — cache-aware bulk refresh (the default button).
  * `refresh_item(...)` — force a fresh live dig for one item (the live button).

Fail-closed: an item kist can't price is simply LEFT OUT of the CSV and
recorded in `failures[]` with its reason. The auditor then flags it
`market-no-reference` for a human — an unpriced item is never silently passed.
"""
from __future__ import annotations

import csv
import datetime
import json
from dataclasses import dataclass, field
from pathlib import Path

from .kist_bridge import (
    DEFAULT_MODE, MarketQuote, KistResearchError, research_price)

CACHE_DIRNAME = "benchmarks"
CACHE_FILE = "benchmarks-cache.json"
MARKET_CSV = "market-pricebook.csv"
SIDECAR = "market-benchmarks.json"
DEFAULT_MAX_AGE_DAYS = 30


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _cache_key(sku: str, description: str, region: str) -> str:
    return f"{sku.strip()}|{description.strip()}|{region.strip()}"


@dataclass
class BenchmarkResult:
    market_csv: Path
    sidecar: Path
    researched: int = 0
    reused: int = 0
    quotes: list[dict] = field(default_factory=list)
    failures: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "marketCsv": str(self.market_csv),
            "sidecar": str(self.sidecar),
            "researched": self.researched,
            "reused": self.reused,
            "priced": len(self.quotes),
            "failures": self.failures,
        }


def items_from_receipt(receipt: dict) -> list[tuple[str, str]]:
    """Distinct (sku, description) actually seen in an audit — research exactly
    what we bought, nothing invented."""
    seen: set[str] = set()
    items: list[tuple[str, str]] = []
    for inv in receipt.get("invoices", []):
        for line in inv.get("lines", []):
            sku = str(line.get("sku", "")).strip()
            desc = str(line.get("description", "")).strip()
            if not sku and not desc:
                continue
            key = f"{sku}|{desc}".upper()
            if key in seen:
                continue
            seen.add(key)
            items.append((sku, desc))
    return items


def _load_cache(cache_dir: Path) -> dict:
    p = cache_dir / CACHE_FILE
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError:
        return {}  # a corrupt cache is not authoritative — re-research


def _fresh(entry: dict, max_age_days: int) -> bool:
    stamp = entry.get("as_of", "")
    if not stamp:
        return False
    try:
        when = datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        return False
    age = datetime.datetime.now(datetime.timezone.utc) - when
    return age.days < max_age_days


def _write_outputs(cache_dir: Path, cache: dict) -> tuple[Path, Path, list[dict]]:
    """Materialise the PriceBook CSV + provenance sidecar from the cache."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    quotes = sorted(cache.values(), key=lambda q: (q.get("sku", ""), q.get("description", "")))

    market_csv = cache_dir / MARKET_CSV
    with open(market_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["sku", "description", "unit_price"])
        for q in quotes:
            w.writerow([q["sku"], q["description"], f"{q['unit_price_usd']:.2f}"])

    sidecar = cache_dir / SIDECAR
    sidecar.write_text(json.dumps(
        {"generatedAt": _now_iso(), "count": len(quotes), "benchmarks": quotes},
        indent=2, sort_keys=True))
    return market_csv, sidecar, quotes


def refresh_all(items: list[tuple[str, str]], cache_dir: Path, *,
                region: str = "United States", mode: str = DEFAULT_MODE,
                force: bool = False,
                max_age_days: int = DEFAULT_MAX_AGE_DAYS) -> BenchmarkResult:
    """Cache-aware bulk research. Reuses fresh cached quotes unless `force`."""
    cache_dir = Path(cache_dir)
    cache = _load_cache(cache_dir)
    result = BenchmarkResult(market_csv=cache_dir / MARKET_CSV,
                             sidecar=cache_dir / SIDECAR)

    for sku, desc in items:
        key = _cache_key(sku, desc, region)
        cached = cache.get(key)
        if cached and not force and _fresh(cached, max_age_days):
            result.reused += 1
            continue
        try:
            quote = research_price(sku, desc, region=region, mode=mode,
                                   as_of=_now_iso())
        except KistResearchError as e:
            result.failures.append({"sku": sku, "description": desc,
                                    "reason": e.reason, "detail": e.detail})
            continue
        cache[key] = quote.to_dict()
        result.researched += 1

    market_csv, sidecar, quotes = _write_outputs(cache_dir, cache)
    (cache_dir / CACHE_FILE).write_text(json.dumps(cache, indent=2, sort_keys=True))
    result.market_csv, result.sidecar, result.quotes = market_csv, sidecar, quotes
    return result


def refresh_item(sku: str, description: str, cache_dir: Path, *,
                 region: str = "United States",
                 mode: str = DEFAULT_MODE) -> MarketQuote:
    """Force a fresh live research for ONE item (the 'Check live' button).

    Updates the cache + rewrites the CSV/sidecar. Raises KistResearchError on
    failure so the UI can show the named reason rather than a fake price.
    """
    cache_dir = Path(cache_dir)
    quote = research_price(sku, description, region=region, mode=mode,
                           as_of=_now_iso())
    cache = _load_cache(cache_dir)
    cache[_cache_key(sku, description, region)] = quote.to_dict()
    _write_outputs(cache_dir, cache)
    (cache_dir / CACHE_FILE).write_text(json.dumps(cache, indent=2, sort_keys=True))
    return quote
