#!/bin/sh
# CI check: two signings with the same local identity give the same designated requirement.
set -ex
export ORDCAT_SIGN_DIR="$RUNNER_TEMP/ordcat-sign"
rm -rf /tmp/a /tmp/b; mkdir -p /tmp/a /tmp/b
ditto build/OrdCat.app /tmp/a/OrdCat.app; ditto build/OrdCat.app /tmp/b/OrdCat.app
sh Resources/localsign.sh /tmp/a/OrdCat.app
sh Resources/localsign.sh /tmp/b/OrdCat.app
RA=$(codesign -d -r- /tmp/a/OrdCat.app 2>&1 | grep designated)
RB=$(codesign -d -r- /tmp/b/OrdCat.app 2>&1 | grep designated)
echo "$RA"; echo "$RB"
[ "$RA" = "$RB" ]
case "$RA" in *certificate*) ;; *) echo "not certificate-based"; exit 1;; esac
codesign -dv /tmp/a/OrdCat.app 2>&1 | grep -v adhoc
