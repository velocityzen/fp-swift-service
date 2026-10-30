#!/bin/bash
# Usage: stop-example-with-sigterm.sh <Example executable>
#
# Runs the Example's `requests`, which runs until a signal, stops it with
# SIGTERM, and checks that it shut down gracefully: exit status 0 and an
# `outcome: SIGTERM` line. This is what runs the signal handler and pipe in
# a build whose tests can't run (Musl).
#
# SIGTERM is sent once the process catches it (bit 15 of SigCgt in
# /proc/<pid>/status): sent earlier, it would end the process by its
# default action.
set -euo pipefail
example=$1

log="$(mktemp)"
"$example" requests > "$log" &
pid=$!
trap 'cat "$log"' EXIT

caught() { awk '/^SigCgt:/ { print substr($2, 9) }' "/proc/$pid/status"; }
for _ in $(seq 100); do
    [ $(( 0x$(caught) & 0x4000 )) -ne 0 ] && break
    sleep 0.1
done

kill -TERM "$pid"
status=0
wait "$pid" || status=$?
test "$status" -eq 0
grep -q '^outcome: SIGTERM' "$log"
