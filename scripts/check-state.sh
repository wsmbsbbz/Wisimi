#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
cat > "$check_dir/main.swift" <<'SWIFT'
@main
struct Check {
    @MainActor
    static func main() async {
        PlaybackStateSelfCheck.run()
        SleepTimerSelfCheck.run()
        await WorksPageStateSelfCheck.run()
        print("State checks passed")
    }
}
SWIFT
swiftc -D DEBUG -parse-as-library -module-cache-path "$check_dir/cache" \
    Wisimi/Features/Works/PlaybackState.swift Wisimi/Features/Works/SleepTimer.swift \
    Wisimi/Features/Works/WorksPageState.swift Wisimi/Features/Works/WorksModels.swift \
    Wisimi/Features/Works/ASMRClient.swift Wisimi/Features/Works/AuthSession.swift \
    Wisimi/Shared/Extensions/DurationFormat.swift Wisimi/Shared/Extensions/ErrorMessage.swift \
    "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
