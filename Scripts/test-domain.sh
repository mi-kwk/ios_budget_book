#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
xcrun swiftc "$repo_root/BudgetBook/Domain/Models.swift" "$repo_root/BudgetBook/Domain/EntrySearch.swift" "$repo_root/BudgetBook/Domain/CalendarSupport.swift" "$repo_root/BudgetBook/Data/BudgetRepository.swift" "$repo_root/BudgetBook/Data/BackupService.swift" "$repo_root/BudgetBook/Data/CloudBackupService.swift" "$repo_root/Tests/BackupTests.swift" "$repo_root/Tests/CloudBackupTests.swift" "$repo_root/Tests/RefundTests.swift" "$repo_root/Tests/CategoryTests.swift" "$repo_root/Tests/BookTests.swift" "$repo_root/Tests/TagTests.swift" "$repo_root/Tests/CalendarTests.swift" "$repo_root/Tests/SearchTests.swift" "$repo_root/Tests/main.swift" -o "$test_tmp/domain-tests"
"$test_tmp/domain-tests"
