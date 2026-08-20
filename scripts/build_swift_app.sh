#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/apps/swift/InvoiceAuditDemo"
APP="$ROOT/dist/Invoice Audit.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

swift build --package-path "$PACKAGE" -c release

mkdir -p "$MACOS" "$RESOURCES"
cp "$PACKAGE/.build/release/InvoiceAuditDemo" "$MACOS/InvoiceAuditDemo"
chmod +x "$MACOS/InvoiceAuditDemo"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>InvoiceAuditDemo</string>
  <key>CFBundleIdentifier</key>
  <string>com.kist.invoice-audit.demo</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Invoice Audit</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$RESOURCES/invoice-audit-root" <<EOF
$ROOT
EOF

echo "$APP"
