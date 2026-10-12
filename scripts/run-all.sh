#!/usr/bin/env bash
# Run every numbered script in order and stop at the first failure. Safe to re-run.
#
#   ./scripts/run-all.sh           # from the host (it forwards into the toolbox container)
#   ./scripts/run-all.sh --full    # the load test runs its full ~6 min profile instead of the 30 s smoke profile
#
# Roughly 12-15 minutes on a first run (image pulls included).
set -euo pipefail

# On the host: make sure the toolbox is up, then run this same script inside it.
if [ "${IN_TOOLBOX:-}" != 1 ]; then
  cd "$(dirname "$0")/.."
  command -v docker >/dev/null || { echo "run-all: docker is required" >&2; exit 1; }
  if ! docker compose ps --status running --services 2>/dev/null | grep -qx toolbox; then
    echo "run-all: the toolbox is not running, starting it (docker compose up -d)"
    docker compose up -d
  fi
  export MSYS_NO_PATHCONV=1   # Git Bash on Windows would rewrite /scripts/... into a Windows path
  exec docker compose exec -T -e PROFILE toolbox bash /scripts/run-all.sh "$@"
fi

. "$(dirname "$0")/lib/common.sh"
FULL=0
[ "${1:-}" = "--full" ] && FULL=1
[ "$FULL" = 1 ] || export PROFILE="${PROFILE:-smoke}"   # only the load test reads PROFILE; smoke keeps run-all short

cd "$(dirname "$0")"
names=(); results=(); seconds=()
t_all=$(date +%s)
rc=0
for s in [0-9][0-9]-*.sh; do
  [ -e "$s" ] || continue
  log "=================== $s"
  t0=$(date +%s)
  if bash "$s"; then res=OK; else res=FAILED; rc=1; fi
  names+=("$s"); results+=("$res"); seconds+=("$(( $(date +%s) - t0 ))")
  [ "$res" = OK ] || break
done

echo
log "summary"
printf '  %-26s %-8s %s\n' script result seconds
for i in "${!names[@]}"; do printf '  %-26s %-8s %s\n' "${names[$i]}" "${results[$i]}" "${seconds[$i]}"; done
log "total: $(( $(date +%s) - t_all )) s"
[ "$rc" = 0 ] && log "ALL SCRIPTS PASSED" || warn "stopped at the first failure: ${names[${#names[@]}-1]}"
exit "$rc"
