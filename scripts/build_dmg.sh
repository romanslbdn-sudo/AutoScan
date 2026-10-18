#!/bin/bash
# Збирає AutoScan.app (Intel + Apple Silicon) і пакує в AutoScan.dmg.
# Запускається на macOS: локально або в GitHub Actions.
set -euo pipefail

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
APP="$OUT/AutoScan.app"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "▶ Компіляція (universal: arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AutoScan"
lipo -info "$BIN"

echo "▶ Збирання AutoScan.app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoScan"

# Іконка .icns з PNG
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AutoScan</string>
  <key>CFBundleDisplayName</key><string>AutoScan</string>
  <key>CFBundleIdentifier</key><string>ua.autoscan.app</string>
  <key>CFBundleExecutable</key><string>AutoScan</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>uk</string>
  <key>CFBundleLocalizations</key><array><string>uk</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>AutoScan — діагностика OBD2</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>AutoScan використовує Bluetooth, щоб підключитися до вашого OBD2-адаптера.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>AutoScan підключається до Wi‑Fi адаптера OBD2 у локальній мережі.</string>
</dict>
</plist>
PLIST

echo "▶ Підпис (ad-hoc)…"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "▶ Створення AutoScan.dmg…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Як відкрити вперше.txt" <<'TXT'
ВСТАНОВЛЕННЯ AutoScan

1. Перетягніть AutoScan у папку «Applications» (Програми).
2. Перший запуск: відкрийте AutoScan. macOS скаже, що не може перевірити розробника —
   натисніть «Готово» (не «В кошик»).
3. Відкрийте  → Системні параметри → Приватність і безпека.
   Прокрутіть донизу — там буде «AutoScan заблоковано». Натисніть «Усе одно відкрити»
   і підтвердіть паролем.
4. Далі програма відкриватиметься звичайно.

Це потрібно один раз: програма не підписана платним сертифікатом Apple.
TXT

hdiutil create -volname "AutoScan" -srcfolder "$STAGE" -ov -format UDZO "$OUT/AutoScan.dmg"
rm -rf "$STAGE"
echo "✔ Готово: $OUT/AutoScan.dmg"
