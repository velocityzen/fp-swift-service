#!/bin/bash
# Usage: coverage-report.sh <label>
#
# Reports the coverage of the tests `swift test --enable-code-coverage` just
# ran, to the log and to the job summary under "Coverage: <label>". No
# threshold.
#
# The test code is in `<name>.xctest` with the native build system (Swift
# 6.3). With swift-build (6.4) a test product is a thin `<name>-test-runner`
# launcher and a `<name>.so` beside it, and the code, so its coverage, is in
# the `.so`.
set -euo pipefail
label=$1

bin="$(swift build --show-bin-path)"
profdata="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
objects=()
for xctest in "$bin"/*.xctest; do
    if [ -f "$xctest" ]; then objects+=("-object=$xctest"); fi
done
for runner in "$bin"/*-test-runner; do
    if [ -f "$runner" ]; then objects+=("-object=${runner%-test-runner}.so"); fi
done
if [ ${#objects[@]} -eq 0 ]; then
    echo "No test binaries in $bin:"
    ls -la "$bin"
    exit 1
fi

report="$(llvm-cov report "${objects[@]}" -instr-profile="$profdata" -ignore-filename-regex='/(\.build|Tests)/')"
echo "$report"
printf '### Coverage: %s\n\n```\n%s\n```\n' "$label" "$report" >> "$GITHUB_STEP_SUMMARY"
