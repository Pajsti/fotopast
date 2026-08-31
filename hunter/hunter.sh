#!/bin/sh
# hunter.sh - orchestrator. Spousti se z /tmp/mnt/sdcard/ubia_test, tedy
# pri KAZDEM probuzeni zarizeni (viz sdcard-root/ubia_test a spec sekce
# 4.1). Neni to demon - je to uloha, ktera se pri kazdem probuzeni podiva,
# co se od minula nakupilo, a snazi se to dohnat (spec sekce 2).
#
# Poradi kroku a duvody jsou zdokumentovane v
# docs/superpowers/specs/2026-08-27-hunter-design.md, sekce 4.2 a 4.3.
# Tady jen strucne to nejdulezitejsi:
#
#   - touch /tmp/stopWdg drzi PO CELOU DOBU behu, ne jen pri SIGSTOP -
#     i zpracovani SMS muze trvat desitky sekund (AT timeouty) a
#     watchdog by jinak mohl zarizeni resetovat driv, nez se stihne
#     odeslat cokoli.
#   - SIGSTOP na ubia_first NEZABIJI, jen zmrazi - aplikace nestihne
#     pozadat MCU o vypnuti. Po SIGCONT dokonci svuj upload a usne sama.
#   - Signaly se volaji VZDY JMENEM (STOP/CONT/TERM/HUP), nikdy cislem -
#     na MIPS maji SIGSTOP/SIGCONT jina cisla nez na x86/ARM.
#   - cleanup() bezi za VSECH okolnosti (trap na EXIT/INT/TERM/HUP) -
#     padly skript nesmi nechat aplikaci zamrzlou ani watchdog vypnuty.

# absolutni cesta k sobe samemu, at uz je HUNTER_DIR spustene odkudkoli
HUNTER_DIR=$(dirname "$0")
case "$HUNTER_DIR" in
    /*) ;;
    *) HUNTER_DIR="$(pwd)/$HUNTER_DIR" ;;
esac

SDCARD="/tmp/mnt/sdcard"
STATE_DIR="$HUNTER_DIR/state"
CONFIG_FILE="$HUNTER_DIR/config.txt"
LOG_FILE="$HUNTER_DIR/log.txt"

mkdir -p "$STATE_DIR" 2>/dev/null

. "$HUNTER_DIR/lib/common.sh"
. "$HUNTER_DIR/lib/status.sh"
. "$HUNTER_DIR/lib/command.sh"
. "$HUNTER_DIR/lib/mail.sh"
. "$HUNTER_DIR/lib/sms.sh"

rotate_log_if_needed
load_config

RUN_START=$(date +%s)
RUN_DEADLINE_TS=$((RUN_START + RUN_DEADLINE))
MAIN_PID=$$

if ! acquire_lock; then
    log "jina instance hunter.sh uz bezi, koncim"
    exit 0
fi

STOPPED_APP=0
APP_PID=""
WATCHDOG_TIMER_PID=""

# cleanup - MUSI probehnout za vsech okolnosti. Poradi je dulezite:
# nejdriv odmrazit aplikaci, teprve pak uklidit stopWdg - watchdog nikdy
# nesmi videt zamrzlou aplikaci bez ochrany.
cleanup() {
    if [ "$STOPPED_APP" = 1 ] && [ -n "$APP_PID" ]; then
        kill -CONT "$APP_PID" 2>/dev/null
    fi
    if [ -n "$WATCHDOG_TIMER_PID" ]; then
        kill "$WATCHDOG_TIMER_PID" 2>/dev/null
    fi
    rm -f /tmp/stopWdg
    release_lock
}
trap cleanup EXIT INT TERM HUP

# vnejsi pojistka: kdyby hlavni beh z nejakeho duvodu neskoncil do
# RUN_DEADLINE, ukonci ho natvrdo. Vlastni C nastroje (atcmd/smssend/
# smsrecv/mailsend) uz maji vlastni timeouty na kazde operaci - tohle je
# jen posledni pojistka pro pripad, ze by neco viselo jinak, nez cekame.
(
    sleep "$RUN_DEADLINE"
    kill -TERM "$MAIN_PID" 2>/dev/null
    sleep 5
    kill -KILL "$MAIN_PID" 2>/dev/null
) &
WATCHDOG_TIMER_PID=$!

touch /tmp/stopWdg
log "=== hunter start (deadline ${RUN_DEADLINE}s) ==="

wait_for_at_port
sync_clock_from_modem

process_sms

snap_list=$(wait_for_candidates)

if [ -n "$snap_list" ]; then
    APP_PID=$(pidof ubia_first)

    if [ -n "$APP_PID" ]; then
        kill -STOP "$APP_PID"
        STOPPED_APP=1
        log "ubia_first (pid $APP_PID) zmrazen"
    else
        log "VAROVANI: ubia_first neni v ps, pokracuji bez SIGSTOP"
    fi

    sent=0
    old_ifs="$IFS"
    IFS='
'
    for snap in $snap_list; do
        IFS="$old_ifs"
        [ "$sent" -ge "$MAX_SEND_PER_WAKE" ] && break

        if send_snap "$snap"; then
            printf '%s\n' "$snap" >> "$STATE_DIR/sent_list.txt"
            sync
            sent=$((sent + 1))
            log "odeslano: $snap"
        else
            log "CHYBA pri odesilani (zkusi se priste): $snap"
        fi
        IFS='
'
    done
    IFS="$old_ifs"

    if [ "$STOPPED_APP" = 1 ]; then
        kill -CONT "$APP_PID" 2>/dev/null
        STOPPED_APP=0
        log "ubia_first pokracuje"
    fi

    # dat aplikaci chvili, at obnovi heartbeat, nez cleanup odstrani
    # stopWdg
    sleep 5
else
    log "nic k odeslani"
fi

log "=== hunter konec ==="
exit 0
