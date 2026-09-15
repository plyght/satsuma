#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fix=0
[[ "${1:-}" == "--fix" ]] && fix=1

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
skip() { printf '\033[33mskip: %s\033[0m\n' "$1"; }

step "format"
if command -v swift-format >/dev/null; then
  if (( fix )); then
    swift-format format --in-place --recursive Sources Tests
  fi
  swift-format lint --strict --recursive Sources Tests
else
  skip "swift-format not installed (wax install swift-format)"
fi

step "lint"
if command -v swiftlint >/dev/null; then
  swiftlint lint --strict
else
  skip "swiftlint not installed (wax install swiftlint)"
fi

step "type-check / build"
brisk build

step "tests"
brisk test

printf '\n\033[32mall checks passed\033[0m\n'
