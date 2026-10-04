#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
python3 Tests/CoverageGateChecks.py
swiftc -D DEBUG -parse-as-library -profile-generate -profile-coverage-mapping \
    -module-cache-path "$check_dir/cache" \
    Wisimi/Features/Works/{ASMRClient,AuthSession,WorksModels,WorksPageState,WorksBrowserState,WorksNavigation,PlaylistCatalog,WorkDetailPageState,DownloadStore,TTSModels,TTSCoordinator,TTSMixSettings,EdgeOnlineTTSClient,OpenRouterTTSClient,OpenRouterTokenStore}.swift \
    Wisimi/Shared/Storage/KeychainItem.swift Wisimi/Shared/Extensions/{DurationFormat,ErrorMessage}.swift \
    Tests/RefactorChecks.swift -o "$check_dir/check"
LLVM_PROFILE_FILE="$check_dir/check.profraw" "$check_dir/check"
xcrun llvm-profdata merge -sparse "$check_dir/check.profraw" -o "$check_dir/check.profdata"
coverage_sources=(
    Wisimi/Features/Works/{TTSCoordinator,WorksBrowserState,WorksNavigation,PlaylistCatalog,WorkDetailPageState}.swift \
    Wisimi/Shared/Storage/KeychainItem.swift Wisimi/Features/Works/TTSMixSettings.swift Wisimi/Features/Works/OpenRouterTokenStore.swift
)
xcrun llvm-cov report "$check_dir/check" -instr-profile="$check_dir/check.profdata" "${coverage_sources[@]}"
xcrun llvm-cov export -summary-only "$check_dir/check" -instr-profile="$check_dir/check.profdata" \
    "${coverage_sources[@]}" | python3 scripts/verify-refactor-coverage.py "${coverage_sources[@]}"
