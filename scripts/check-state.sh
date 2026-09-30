#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
cat > "$check_dir/main.swift" <<'SWIFT'
PlaybackStateSelfCheck.run()
print("State checks passed")
SWIFT
swiftc -D DEBUG -module-cache-path "$check_dir/cache" \
    Wisimi/Features/Works/PlaybackState.swift "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
