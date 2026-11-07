#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
xcrun swiftc "$repo_root/BudgetBook/Domain/Models.swift" "$repo_root/Tests/main.swift" -o "$test_tmp/domain-tests"
"$test_tmp/domain-tests"
