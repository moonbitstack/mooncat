#!/usr/bin/env bash
# The multi-process supervisor with real processes, on Linux: connections spread across workers,
# a killed worker is replaced, a stopped supervisor stops them all, and a worker that cannot start
# ends the supervisor with exit code 3.
#
#     moon build --target native
#     bash scripts/checks/check_workers.sh
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
server="$root/_build/native/debug/build/examples/08-workers/08-workers.exe"
test -x "$server" || { echo "build first: moon build --target native"; exit 2; }
port=18990
url="http://127.0.0.1:$port/"
failed=0

say() { # verdict name detail
  [ "$1" = ok ] || failed=1
  printf '%-4s %-44s %s\n' "$1" "$2" "${3:-}"
}
ask() { curl -s --max-time 2 "$url"; }
children() { pgrep -P "$1" | wc -l; }

"$server" --workers 4 --port $port --log-level warning &
pid=$!
trap 'kill -KILL $pid 2>/dev/null; pkill -KILL -P $pid 2>/dev/null' EXIT

for _ in $(seq 50); do [ -n "$(ask)" ] && break; sleep 0.1; done
[ "$(children $pid)" = 4 ] && say ok "four workers run" || say FAIL "four workers run" "$(children $pid)"

seen=$(for _ in $(seq 200); do ask; done | sort -u)
n=$(printf '%s\n' "$seen" | wc -l)
[ "$n" -ge 2 ] && say ok "connections spread across workers" "$n of 4" || say FAIL "connections spread across workers" "$seen"
grep -q alone <<< "$seen" && say FAIL "the supervisor serves nothing" || say ok "the supervisor serves nothing"

victim=$(pgrep -P $pid | head -1)
kill -KILL "$victim"
sleep 1.5
[ "$(children $pid)" = 4 ] && say ok "a killed worker is replaced" || say FAIL "a killed worker is replaced" "$(children $pid)"
pgrep -P $pid | grep -qx "$victim" && say FAIL "the replacement is a new process" || say ok "the replacement is a new process"
[ -n "$(ask)" ] && say ok "serving goes on" || say FAIL "serving goes on"

workers=$(pgrep -P $pid)
kill -TERM $pid
stopped=no
for _ in $(seq 100); do kill -0 $pid 2>/dev/null || { stopped=yes; break; }; sleep 0.1; done
[ $stopped = yes ] && say ok "the supervisor stops on SIGTERM" || say FAIL "the supervisor stops on SIGTERM"
left=0
for w in $workers; do kill -0 "$w" 2>/dev/null && left=$((left + 1)); done
[ $left = 0 ] && say ok "every worker stops with it" || say FAIL "every worker stops with it" "$left left"
[ -z "$(ask)" ] && say ok "the port is closed" || say FAIL "the port is closed"

WORKERS_FAIL=1 timeout 10 "$server" --workers 2 --port $port --lifespan on --log-level critical > /dev/null 2>&1
code=$?
[ $code = 3 ] && say ok "a worker that cannot start ends it with 3" || say FAIL "a worker that cannot start ends it with 3" "exit $code"

exit $failed
