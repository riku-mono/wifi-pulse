#!/bin/sh
# 開発用ビルドのアプリを LaunchServices の登録から外す（Spotlight や「このアプリケーションで開く」に同じアプリが並ばないように）。
# /Applications にあるものは残す。ファイルは消さない。
#
#   scripts/unregister-dev-builds.sh              # WiFiPulse.app
#   scripts/unregister-dev-builds.sh Mixer.app    # ほかのアプリも指定できる
set -eu

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ $# -gt 0 ] || set -- WiFiPulse.app

for app in "$@"; do
    "$LSREGISTER" -dump \
        | sed -n "s/^path: *\(.*\/$app\) (0x[0-9a-f]*)$/\1/p" \
        | sort -u \
        | while IFS= read -r path; do
            case "$path" in
                /Applications/*) continue ;;
            esac
            "$LSREGISTER" -u "$path" 2>/dev/null || true
            echo "unregistered: $path"
        done
done
