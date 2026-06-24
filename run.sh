#!/bin/bash
# VolumeMonitor 构建 & 启动
set -euo pipefail

cd "$(dirname "$0")"

SIGNING_NAME="VolumeMonitor Local Code Signing"
SIGNING_PASSWORD="volume-monitor"
SIGNING_DIR="$PWD/build/codesign"
SIGNING_KEYCHAIN="$SIGNING_DIR/VolumeMonitor.keychain-db"

ensure_keychain_search_list() {
  local keychain
  local trimmed
  local exists=0
  local keychains=()

  while IFS= read -r keychain; do
    trimmed="${keychain#*\"}"
    trimmed="${trimmed%\"}"
    [ -n "$trimmed" ] || continue
    if [ "$trimmed" = "$SIGNING_KEYCHAIN" ]; then
      exists=1
    fi
    keychains+=("$trimmed")
  done < <(security list-keychains -d user)

  if [ "$exists" -eq 0 ]; then
    security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${keychains[@]}"
  fi
}

prepare_signing_keychain() {
  security unlock-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
  security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN" >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$SIGNING_PASSWORD" \
    "$SIGNING_KEYCHAIN" >/dev/null 2>&1
  ensure_keychain_search_list
}

ensure_signing_identity() {
  mkdir -p "$SIGNING_DIR"

  identity_output="$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null || true)"
  if echo "$identity_output" | grep -q "\"$SIGNING_NAME\"" && echo "$identity_output" | grep -q "1 valid identities found"; then
    prepare_signing_keychain
    return
  fi

  echo "🔐 Creating local signing identity..."
  cat > "$SIGNING_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = codesign_ext
prompt = no

[ req_distinguished_name ]
CN = $SIGNING_NAME

[ codesign_ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$SIGNING_DIR/VolumeMonitorLocal.key" \
    -out "$SIGNING_DIR/VolumeMonitorLocal.crt" \
    -config "$SIGNING_DIR/openssl.cnf" >/dev/null 2>&1

  openssl pkcs12 -legacy -export \
    -inkey "$SIGNING_DIR/VolumeMonitorLocal.key" \
    -in "$SIGNING_DIR/VolumeMonitorLocal.crt" \
    -out "$SIGNING_DIR/VolumeMonitorLocal.p12" \
    -name "$SIGNING_NAME" \
    -passout "pass:$SIGNING_PASSWORD" >/dev/null 2>&1

  rm -f "$SIGNING_KEYCHAIN"
  security create-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
  security unlock-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
  security import "$SIGNING_DIR/VolumeMonitorLocal.p12" \
    -k "$SIGNING_KEYCHAIN" \
    -P "$SIGNING_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$SIGNING_PASSWORD" \
    "$SIGNING_KEYCHAIN" >/dev/null 2>&1
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$SIGNING_KEYCHAIN" \
    "$SIGNING_DIR/VolumeMonitorLocal.crt" >/dev/null
  prepare_signing_keychain
}

echo "🔨 Building..."
swift build -c release 2>&1 | grep -E "error:|Build complete|Building"

echo "📦 Preparing app bundle..."
mkdir -p build/VolumeMonitor.app/Contents/MacOS
mkdir -p build/VolumeMonitor.app/Contents/Resources

needs_sign=0
source_hash="$(shasum -a 256 .build/release/VolumeMonitor | cut -d ' ' -f 1)"
hash_file="build/VolumeMonitor.app/Contents/Resources/VolumeMonitor.source.sha256"

if ! cmp -s Packaging/Info.plist build/VolumeMonitor.app/Contents/Info.plist; then
  cp Packaging/Info.plist build/VolumeMonitor.app/Contents/Info.plist
  needs_sign=1
fi

echo "📦 Copying binary..."
if [ ! -f "$hash_file" ] || [ "$(cat "$hash_file")" != "$source_hash" ]; then
  cp .build/release/VolumeMonitor build/VolumeMonitor.app/Contents/MacOS/VolumeMonitor
  echo "$source_hash" > "$hash_file"
  needs_sign=1
fi

if [ -f "$SIGNING_KEYCHAIN" ]; then
  prepare_signing_keychain
fi

if ! codesign --verify build/VolumeMonitor.app 2>/dev/null; then
  needs_sign=1
fi

signature_details="$(codesign -d -vvv build/VolumeMonitor.app 2>&1 || true)"
if [[ "$signature_details" != *"Authority=$SIGNING_NAME"* ]]; then
  needs_sign=1
fi

if [ "$needs_sign" -eq 1 ]; then
  ensure_signing_identity
  echo "🔑 Re-signing..."
  signing_identity="$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | awk -v name="$SIGNING_NAME" '$0 ~ name {print $2; exit}')"
  if [ -z "$signing_identity" ]; then
    echo "❌ Signing identity not found in $SIGNING_KEYCHAIN" >&2
    exit 1
  fi
  codesign --force --sign "$signing_identity" build/VolumeMonitor.app
  signature_details="$(codesign -d -vvv build/VolumeMonitor.app 2>&1 || true)"
  if [[ "$signature_details" != *"Authority=$SIGNING_NAME"* ]]; then
    echo "❌ Signing verification failed: app is not signed by $SIGNING_NAME" >&2
    exit 1
  fi
else
  echo "🔑 Signature unchanged"
fi

echo "🛑 Killing old instance..."
pkill -9 -f "VolumeMonitor" 2>/dev/null || true
sleep 0.3

echo "🚀 Launching..."
open build/VolumeMonitor.app

echo "✅ Done"
