#!/bin/zsh
# Build, sign with a stable identity, and run BrowseFast. `./run.sh build` only builds and signs.
#
# swift build signs ad hoc, which gives every build a new code identity. The Keychain then treats each
# build as a different app and asks for your password. Signing with your Apple Development certificate
# and a fixed identifier keeps the identity stable, so "Always Allow" sticks across rebuilds.
set -e
cd "${0:A:h}"

swift build

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --identifier app.browsefast .build/debug/BrowseFast
else
  echo "warning: no Apple Development certificate found, so the Keychain will ask for your password after every build" >&2
fi

[[ "$1" == "build" ]] || exec .build/debug/BrowseFast
