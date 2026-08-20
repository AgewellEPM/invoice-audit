#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export INVOICE_AUDIT_ROOT="$ROOT"
cd "$ROOT"

exec swift run --package-path apps/swift/InvoiceAuditDemo InvoiceAuditDemo
