#!/bin/bash
#
# StikJIT.framework 를 **소스에서** 빌드해 Runtime/ 에 넣는다.
#
# ── 왜 릴리스 바이너리를 안 쓰는가 ──────────────────────────────────────────
# 업스트림이 올려 둔 StikJIT.xcframework 는 Swift 6.4 로 빌드돼 있고, 그 인터페이스는
# `Swift::Sendable` 같은 새 문법을 쓴다. Xcode 26.1(Swift 6.2.1)로 열면 파싱부터 실패한다:
#     error: expected '{' in struct   (arm64-apple-ios.private.swiftinterface:12)
# 소스에서 빌드하면 우리 컴파일러가 만든 인터페이스가 들어가므로 이 문제가 사라진다.
#
# ── 두 가지 비표준 빌드 설정 ────────────────────────────────────────────────
#   BUILD_LIBRARY_FOR_DISTRIBUTION=NO
#     YES 로 두면 .swiftinterface 가 생기는데, 모듈 이름(StikJIT)과 그 안의 enum 이름이
#     같아서 우리 컴파일러가 `StikJIT.DDIPaths` 를 enum 의 멤버로 해석해 버린다:
#       error: 'DDIPaths' is not a member type of enum 'StikJIT.StikJIT'
#     NO 면 바이너리 .swiftmodule 이 들어가고(같은 컴파일러로 쓰므로 안전) 문제가 없다.
#   GENERATE_INFOPLIST_FILE=YES
#     업스트림 project.yml 에 framework 용 info 가 없어서 Info.plist 가 안 만들어진다.
#     그대로 두면 앱 빌드가 거부한다: "Framework … did not contain an Info.plist".
#
# 사용:  Scripts/build-stikjit.sh [태그]      (기본 1.9.0)
set -euo pipefail

REF="${1:-1.9.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v xcodegen >/dev/null || { echo "xcodegen 이 필요합니다: brew install xcodegen"; exit 1; }

echo "▸ StikJIT ($REF) 받는 중…"
git clone -q --depth 1 --branch "$REF" https://github.com/StephenDev0/StikJIT.git "$WORK/src"

echo "▸ 빌드 (iOS arm64)"
cd "$WORK/src"
xcodegen generate >/dev/null
xcodebuild archive -scheme StikJIT -destination 'generic/platform=iOS' \
  -archivePath "$WORK/StikJIT" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=NO SKIP_INSTALL=NO GENERATE_INFOPLIST_FILE=YES >/dev/null

FRAMEWORK="$WORK/StikJIT.xcarchive/Products/Library/Frameworks/StikJIT.framework"
[ -d "$FRAMEWORK" ] || { echo "✗ 빌드 산출물이 없습니다: $FRAMEWORK"; exit 1; }

rm -rf "$OUT/StikJIT.framework"
mkdir -p "$OUT"
cp -R "$FRAMEWORK" "$OUT/"
echo "완료: Runtime/StikJIT.framework ($(du -sh "$OUT/StikJIT.framework" | cut -f1))"
echo "  스크립트: $(ls "$OUT/StikJIT.framework" | grep -c '\.js$')개 내장(universal.js · legacy.js)"
