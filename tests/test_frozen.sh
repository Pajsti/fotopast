#!/bin/sh
# Overuje idempotenci ensure_app_frozen - tri volaci mista smi zmrazit
# aplikaci dohromady nejvys jednou.
. "$(dirname "$0")/assert.sh"

STOPPED_APP=0
APP_PID=""
FREEZE_CALLS=0
LOG_FILE=/dev/null

log() { :; }
pidof() { echo 4242; }
kill() { FREEZE_CALLS=$((FREEZE_CALLS + 1)); return 0; }

ensure_app_frozen() {
    [ "$STOPPED_APP" = 1 ] && return 0
    APP_PID=$(pidof ubia_first)
    if [ -z "$APP_PID" ]; then
        log "VAROVANI: ubia_first neni v ps, pokracuji bez SIGSTOP"
        return 0
    fi
    kill -STOP "$APP_PID"
    STOPPED_APP=1
    log "ubia_first (pid $APP_PID) zmrazen"
    return 0
}

ensure_app_frozen
ensure_app_frozen
ensure_app_frozen
assert_eq "tri volani = jedno zmrazeni" "$FREEZE_CALLS" "1"
assert_eq "priznak nastaven"            "$STOPPED_APP"  "1"
assert_eq "PID zapamatovan"             "$APP_PID"      "4242"

# kdyz aplikace nebezi, nezmrazi se nic a nespadne to
STOPPED_APP=0; APP_PID=""; FREEZE_CALLS=0
pidof() { echo ""; }
ensure_app_frozen
assert_eq "bez ubia_first se nemrazi" "$FREEZE_CALLS" "0"
assert_eq "priznak zustava 0"         "$STOPPED_APP"  "0"

finish
