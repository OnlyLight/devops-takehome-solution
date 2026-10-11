#!/usr/bin/env bash
# Part 3 harness: put the troubleshooting namespace into the BROKEN or the FIXED state, then run the
# provided verify.sh. Safe to re-run.
#
#   30-troubleshoot.sh --broken   # reset the namespace and apply the original broken-app.yaml
#   30-troubleshoot.sh            # apply troubleshoot/fixed-app.yaml and run verify.sh (expects PASS)
#
# prepare.sh must have run first (05-prepare-nodes.sh does that during bootstrap). Nodes are never touched here.
. "$(dirname "$0")/lib/common.sh"
need kubectl
require_cluster

DIR=/workspace/troubleshoot
NS=troubleshoot

case "${1:-}" in
  --broken)
    f="$DIR/broken-app.yaml"
    # Clean slate: otherwise allow-rules left over from a previous fixed run would hide faults.
    log "resetting namespace $NS"
    kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
    ;;
  "")
    f="$DIR/fixed-app.yaml"
    ;;
  *) die "usage: $0 [--broken]" ;;
esac
[ -f "$f" ] || die "$f not found"

log "applying $(basename "$f")"
kubectl apply -f "$f"

if [ "${1:-}" = "--broken" ]; then
  log "broken state applied. Diagnose it, then fix troubleshoot/fixed-app.yaml and run this script without arguments."
  log "(verify.sh is expected to FAIL now: sh $DIR/verify.sh)"
  exit 0
fi

log "running verify.sh"
sh "$DIR/verify.sh"
