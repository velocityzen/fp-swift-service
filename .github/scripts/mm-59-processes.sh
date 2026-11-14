#!/bin/bash
# Usage: mm-59-processes.sh <count> <filter>
#
# MM-59 debugging, on its branch only. Runs the tests <filter> selects in
# <count> processes of their own, and says how many crashed and how many
# failed otherwise. For a crash it prints the backtracer's crash line and the
# crashed thread, and which test had started last. The tests must be built.
set -uo pipefail
count=$1
filter=$2
crashed=0
failed=0
for i in $(seq "$count"); do
    log="$RUNNER_TEMP/mm-59-$i.log"
    start=$(date +%s)
    if swift test --skip-build --filter "$filter" > "$log" 2>&1; then
        echo "== process $i passed in $(( $(date +%s) - start )) s"
        continue
    fi
    if grep -q 'Program crashed' "$log"; then
        crashed=$((crashed + 1))
        echo "== process $i crashed after $(( $(date +%s) - start )) s"
        grep -E '^◇ Test .* started' "$log" | tail -2
        grep -m1 'Program crashed' "$log"
        awk '/ crashed:$/ { on = 1 } on { print; if (++n >= 14) exit }' "$log"
    else
        failed=$((failed + 1))
        echo "== process $i failed after $(( $(date +%s) - start )) s"
        grep -E 'recorded an issue|Expectation failed|Fatal error|error:' "$log" | head -8
    fi
done
echo "$crashed of $count processes crashed, $failed failed otherwise"
[ "$crashed" -eq 0 ] && [ "$failed" -eq 0 ]
