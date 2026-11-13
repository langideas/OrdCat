#!/bin/sh
# Sign OrdCat.app with a per-Mac self-signed identity so macOS privacy grants
# (Accessibility, Screen Recording, Microphone) survive updates.
# The private key is created on this Mac and never leaves it.
set -e
APP="$1"
DIR="${ORDCAT_SIGN_DIR:-$HOME/Library/OrdCatSigning}"
KC="$DIR/ordcat-signing.keychain-db"
NAME="OrdCat Local Signing"
OSSL=/usr/bin/openssl
mkdir -p "$DIR"; chmod 700 "$DIR"
if [ ! -f "$DIR/kcpass" ]; then $OSSL rand -hex 24 > "$DIR/kcpass"; chmod 600 "$DIR/kcpass"; fi
KCPW=$(cat "$DIR/kcpass")
if [ ! -f "$KC" ] || [ ! -f "$DIR/cert.pem" ]; then
  rm -f "$KC" "$DIR/cert.pem"
  cat > "$DIR/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  $OSSL req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$DIR/cert.cnf" \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
  P12PW=$($OSSL rand -hex 12)
  $OSSL pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
    -out "$DIR/id.p12" -passout "pass:$P12PW"
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  security import "$DIR/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null 2>&1
  rm -f "$DIR/id.p12" "$DIR/key.pem"
fi
security unlock-keychain -p "$KCPW" "$KC"
HASH=$($OSSL x509 -in "$DIR/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
if ! codesign --force --deep --keychain "$KC" --sign "$HASH" "$APP" 2>"$DIR/last-error.txt"; then
  # Some macOS versions only find identities in keychains on the search list.
  case "$(security list-keychains -d user)" in
    *ordcat-signing*) ;;
    *) security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC" ;;
  esac
  codesign --force --deep --keychain "$KC" --sign "$HASH" "$APP"
fi
codesign --verify --deep "$APP"
echo "signed with $HASH"
