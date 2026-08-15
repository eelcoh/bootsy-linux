#!/usr/bin/bash
set -euo pipefail

for file in system/bin/bootsy-status system/libexec/bootsy-disk-health \
    server/bin/bootsy-health server/bin/bootsy-backup; do
    bash -n "$file"
done

grep -q 'bootc-fetch-apply-updates.timer' base/Containerfile
grep -q 'node-exporter' server/Containerfile
grep -q 'cockpit-ws' server/Containerfile
grep -q 'bootsy-backup.timer' server/Containerfile
grep -q 'app.zen_browser.zen' desktop/Containerfile
grep -q 'com.github.tchx84.Flatseal' desktop/Containerfile
grep -q 'exec dms run --session' desktop/Containerfile
grep -q 'gtkgreet' desktop/Containerfile
grep -q 'xwayland disable' desktop/Containerfile
grep -q 'systemctl enable --force greetd.service' desktop/Containerfile
grep -q 'systemctl disable cosmic-greeter.service' desktop/Containerfile
! grep -qE '^[[:space:]]+sddm-x11' desktop/Containerfile
! grep -qE '(^|[[:space:]])gdm([[:space:]\\]|$)' desktop/Containerfile
grep -q 'cosign sign --yes' .github/workflows/build-image.yml

echo 'Bootsy static smoke checks passed.'
