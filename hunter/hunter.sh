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
. "$HUNTER_DIR/lib/mailcmd.sh"
. "$HUNTER_DIR/lib/sms.sh"

rotate_log_if_needed
load_config

RUN_START=$(date +%s)
RUN_DEADLINE_TS=$((RUN_START + RUN_DEADLINE))
MAIN_PID=$$
REQUESTED_SNAPS=""
CLEAR_QUEUE_REQUESTED=0

if ! acquire_lock; then
    log "jina instance hunter.sh uz bezi, koncim"
    exit 0
fi

STOPPED_APP=0
APP_PID=""
WATCHDOG_TIMER_PID=""
MAIL_TIMER_PID=""

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
    if [ -n "$MAIL_TIMER_PID" ]; then
        kill "$MAIL_TIMER_PID" 2>/dev/null
    fi
    rm -f /tmp/stopWdg
    release_lock
}
trap cleanup EXIT INT TERM HUP

# ensure_app_frozen
# Idempotentni: zmrazi ubia_first nejvys jednou za beh. Volaji ji VSECHNA
# mista, ktera potrebuji zarizeni drzet naziv - process_sms, process_mail
# i fotkova vetev. Diky idempotenci se muze volat kolikrat chce.
#
# Volat az ve chvili, kdy je JISTE, ze je co delat - pri probuzeni, kdy
# neni zadny prikaz ani fotka, se nemrazi vubec a zarizeni usne normalne.
#
# Signal se vola JMENEM (-STOP), nikdy cislem - MIPS ma jina cisla.
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

# vnejsi pojistka: kdyby hlavni beh z nejakeho duvodu neskoncil do
# RUN_DEADLINE, ukonci ho natvrdo.
#
# Poradi je tu nosne. Nejdriv SIGTERM sitovym nastrojum, teprve pak
# shellu: kdyz hlavni beh visi v prikazove substituci (mailrecv na
# zaseklem spojeni), SIGTERM poslany JEN shellu se odlozi - POSIX shell
# zpracuje trap az potom, co dite skonci - a nasledny SIGKILL uz cleanup
# obejde uplne. Zustala by zmrazena ubia_first a zamek lezet na karte.
# 2026-09-06 takhle skoncilo 18 behu za sebou.
#
# Timeouty uvnitr nastroju to nenahrazuji, i kdyz uz jsou uplne: tlsnet
# ma timeout na cteni (30 s), DNS (5 s), connect (15 s) i zapis a
# handshake (30 s od posledniho pokroku, doplneno 2026-09-23). Pojistka
# tu zustava pro pripady, ktere zadny z nich nepokryva - zaseknuty AT
# prikaz, chyba v samotnem nastroji, cokoli neocekavaneho.
(
    sleep "$RUN_DEADLINE"
    deadline_kill_tools
    kill -TERM "$MAIN_PID" 2>/dev/null
    sleep 5
    kill -KILL "$MAIN_PID" 2>/dev/null
) &
WATCHDOG_TIMER_PID=$!

touch /tmp/stopWdg
log "=== hunter start (deadline ${RUN_DEADLINE}s) ==="

wait_for_at_port
sync_clock_from_modem

# Kontrola posty dostane VLASTNI, mnohem mensi rozpocet nez cely beh.
#
# Proc: process_mail bezi PRED odesilanim fotek, takze zaseknuty mailrecv
# neznamena "neprisly prikazy", ale "neodesle se nic". Rozbor 195 behu z
# karty (2026-09-23) ukazal, ze prave tohle je nejcastejsi rezim selhani:
# 121 ze 132 nedokoncenych behu umrelo jeste pred zmrazenim aplikace a 46
# z nich presne na RUN_DEADLINE. Po studenem startu, kdy jeste nebezi 4G,
# skonci mailrecv hned na DNS - a presne tehdy fotky chodily. Odtud
# uzivatelovo "posle to az po restartu".
#
# Pojistka je zamerne v shellu, ne jen v C: musi fungovat bez ohledu na
# to, PROC mailrecv visi. (Konkretni pricinu v tlsnet.c - nekonecne
# opakovani na WANT_WRITE - resi samostatna oprava, ale i po ni zustava
# tohle jako posledni zachrana.)
#
# Zabiji se opakovane ve smycce, protoze process_mail vola mailrecv
# vickrat (list unseen, seen, odpovedi) - jedno zabiti by utlo jen prave
# bezici volani a dalsi by viselo znovu.
mail_watchdog_start() {
    (
        sleep "$MAIL_DEADLINE"
        log "kontrola posty prekrocila rozpocet ${MAIL_DEADLINE}s - ukoncuji mailrecv"
        while :; do
            _mp=$(pidof mailrecv 2>/dev/null)
            # Zamerne bez uvozovek: pidof vraci PID oddelene mezerou a
            # chceme signal vsem. Stejny postup jako deadline_kill_tools.
            [ -n "$_mp" ] && kill -TERM $_mp 2>/dev/null
            sleep 2
        done
    ) &
    MAIL_TIMER_PID=$!
}

# Zastavit HNED po process_mail: od teto chvile smi mailrecv bezet znovu
# jako odesilaci cesta (SEND_TRANSPORT=imap pouziva mailrecv append) a
# timer by mu do toho strilel.
mail_watchdog_stop() {
    if [ -n "$MAIL_TIMER_PID" ]; then
        kill "$MAIL_TIMER_PID" 2>/dev/null
        MAIL_TIMER_PID=""
    fi
}

process_sms

mail_watchdog_start
process_mail
mail_watchdog_stop

snap_list=$(wait_for_candidates)

# CLEAR QUEUE: uzivatel rekl, ze celou frontu uz posilat nechce - VCETNE
# souboru, ktere snapready trvale odmita (napr. rozepsanych pri vypadku
# napajeni). Proto cerstvy sken list_unsent_snaps 0 misto $snap_list:
# ten druhy je jen kandidati, kteri projdou snapready, a takovy soubor
# by jinak drzel svuj den navzdy otevreny a cursor navzdy zaseknuty
# (spec 2026-09-03, oprava omezeni 9.3 bod 3). Soubory zustavaji na
# karte, jen se oznaci za vyrizene. Bezi to az tady, po zpracovani vsech
# prikazu, aby byl REQUESTED_SNAPS konecny - skip_snaps vyzadane
# vynechava (spec 2026-09-02, 5 a 7.1). Bezi jen kdyz prikaz dorazil,
# takze to na beznem probuzeni nic nestoji.
if [ "$CLEAR_QUEUE_REQUESTED" = 1 ]; then
    cleared=$(skip_snaps "$(list_unsent_snaps 0)")
    log "CLEAR QUEUE: preskoceno $cleared cekajicich fotek"
    snap_list=""
fi

# MAX_QUEUE: nedodelek se nesmi nafouknout donekonecna. Co je pres
# strop, to se NEJSTARSI preskoci - zapisem do sent_list.txt, takze uz
# se to nenabizi. Soubory na karte zustavaji.
#
# Poradi z find_ready_candidates je chronologicky vzestupne, takze
# "nejstarsi" jsou proste prvni radky.
#
# Bezi to PRED slouchenim s REQUESTED_SNAPS a skip_snaps navic
# vyzadane sama vynechava - vyzadana fotka se timhle nesmi dostat do
# sent_list.txt (spec 2026-09-02, 7.1).
if [ -n "$snap_list" ] && [ "$MAX_QUEUE" -gt 0 ]; then
    queue_n=$(printf '%s' "$snap_list" | grep -c .)
    if [ "$queue_n" -gt "$MAX_QUEUE" ]; then
        drop=$((queue_n - MAX_QUEUE))
        to_skip=""
        keep=""
        i=0
        old_ifs="$IFS"
        IFS='
'
        for cand in $snap_list; do
            IFS="$old_ifs"
            i=$((i + 1))
            if [ "$i" -le "$drop" ]; then
                to_skip="$to_skip$cand
"
            else
                keep="$keep$cand
"
            fi
            IFS='
'
        done
        IFS="$old_ifs"
        skipped=$(skip_snaps "$to_skip")
        snap_list=$(printf '%s' "$keep")
        log "fronta pres strop ($queue_n > $MAX_QUEUE): preskoceno $skipped nejstarsich"
    fi
fi

# Vyzadane fotky (LAST/DATE/GET) se pripoji k automatickym kandidatum,
# aby se mrazilo jen jednou a poslalo v jedne davce.
#
# POZOR na prekryv: vyzadana fotka, ktera jeste NEBYLA odeslana, je
# soucasne platnym automatickym kandidatem - find_ready_candidates (viz
# lib/mail.sh) ji najde take, protoze hleda kandidaty ode dne cursoru
# dal, mimo sent_list.txt, a o vyzadani nic nevi. Bez odstraneni duplicit
# by se stejna cesta objevila v $snap_list dvakrat, poslala by se e-mailem
# dvakrat a KAZDA kopie by se (spravne, viz case nize) vynechala ze sent_list.txt,
# protoze matchuje REQUESTED_SNAPS - vysledkem by byl duplicitni e-mail
# a fotka navzdy oznacovana jako "neodeslana" pro automatiku (dokud by ji
# nekdo znovu nevyzadal). Proto se z automatickeho seznamu pred spojenim
# odstrani kazdy radek, ktery uz je mezi vyzadanymi.
if [ -n "$REQUESTED_SNAPS" ] && [ -n "$snap_list" ]; then
    dedup_list=""
    old_ifs="$IFS"
    IFS='
'
    for cand in $snap_list; do
        IFS="$old_ifs"
        case "
$REQUESTED_SNAPS" in
            *"
$cand"*) IFS='
'; continue ;;
        esac
        if [ -z "$dedup_list" ]; then
            dedup_list="$cand"
        else
            dedup_list="$dedup_list
$cand"
        fi
        IFS='
'
    done
    IFS="$old_ifs"
    snap_list="$dedup_list"
fi

if [ -n "$REQUESTED_SNAPS" ]; then
    if [ -n "$snap_list" ]; then
        snap_list="$REQUESTED_SNAPS
$snap_list"
    else
        snap_list="$REQUESTED_SNAPS"
    fi
fi

if [ -n "$snap_list" ]; then
    ensure_app_frozen

    sent=0
    old_ifs="$IFS"
    IFS='
'
    for snap in $snap_list; do
        IFS="$old_ifs"
        [ "$sent" -ge "$MAX_SEND_PER_WAKE" ] && break
        [ -f "$snap" ] || { IFS='
'; continue; }

        if send_snap "$snap"; then
            # Do sent_list.txt patri jen automaticky odeslane snimky.
            # Vyzadane se tam nezapisuji - jinak by se pri prvnim
            # vyzadani oznacily za odeslane a uz by nikdy neodesly
            # automaticky.
            case "
$REQUESTED_SNAPS" in
                *"
$snap"*) ;;
                *) printf '%s\n' "$snap" >> "$STATE_DIR/sent_list.txt"; sync ;;
            esac
            sent=$((sent + 1))
            log "odeslano: $snap"
        else
            log_error "CHYBA pri odesilani (zkusi se priste): $snap"
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

# Posun cursoru az TED, po odeslani - prave odeslane soubory se tim do
# uzavreni sveho dne zapocitaji hned. Jednou za probuzeni, ne uvnitr
# find_ready_candidates: ta se vola opakovane z pollovaci smycky
# wait_for_candidates (spec 2026-09-02, 3.3).
cursor_advance

# Rozdelane mazani (WIPE) - jedna davka za probuzeni, AZ TED: fotky jsou
# hlavni ucel zarizeni a mazani jim nesmi ujidat rozpocet behu. Kdyz uz
# na davku neni cas, preskoci se a pokracuje se pri dalsim probuzeni -
# znacka v state/ zustava, takze se nic neztrati.
#
# Preruseni uprostred davky je bezpecne: sent_list.txt se prepisuje az
# atomickym mv na konci, takze uz smazane soubory se pri dalsim kole jen
# nenajdou ([ -f ] selze) a vypadnou ze seznamu bez zapocitani.
# Adresa se cte PRED davkou: posledni davka znacku uklidi, takze potom
# uz by nebylo komu hlaseni poslat.
wipe_addr=$(wipe_pending_addr)
if [ -n "$wipe_addr" ]; then
    if [ "$(date +%s)" -lt $((RUN_DEADLINE_TS - 30)) ]; then
        wipe_continue_if_pending
        if [ -n "$WIPE_DONE_NOTICE" ]; then
            send_reply_mail "$wipe_addr" "$WIPE_DONE_NOTICE"
            log "WIPE dokoncen, hlaseni odeslano na $wipe_addr"
        fi
    else
        log "WIPE davka preskocena - do konce behu zbyva min nez 30 s"
    fi
fi

log "=== hunter konec ==="
exit 0
