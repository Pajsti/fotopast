#!/bin/sh
#
# dev-stop.sh -- docasne zastavi originalni aplikaci fotopasti,
#                aby byl klid na praci na Hunteru.
#
# Poradi kroku je zamerne: nejdriv umlcet ubia_watchdog, teprve pak
# zabijet ubia_first. Opacne poradi znamena MCU reset do par sekund
# (ubia_watchdog hlida firstProcLastTime a vola HI_HAL_MCUHOST_JUST_RESET).
#
# system_call_daemon zustava bezet -- je to jen lokalni IPC sbernice.
#
# Navrat do normalu: dev-resume.sh. Jina cesta nez reboot neni.
#
# Pouziti:
#   ./dev-stop.sh          pauza s pojistkou 900 s (15 min)
#   ./dev-stop.sh 3600     pauza s pojistkou 1 h
#   ./dev-stop.sh 3600     spusteno znovu = jen prodlouzeni pojistky
#

HOLD=${1:-900}
LOG=/tmp/hunter_dev.log

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
	echo "$*"
}

case "$HOLD" in
	''|*[!0-9]*)
		echo "pouziti: $0 [sekundy_pojistky]"
		exit 1
		;;
esac

log "=== dev-stop: pauza, pojistka $HOLD s ==="
log "POZOR: ubia_record.db a .dup si mej zazalohovane mimo kartu."

# 0) dotlacit logfile.txt a ubia_record.db na kartu, dokud aplikace jeste zije
sync

# 1) umlcet reset-logiku watchdogu (vendor priznak, viz retezec "stop watchdog by file")
touch /tmp/stopWdg
log "stopWdg nastaven"
sleep 2

# 2) vendor cesta "kill watchdog by usr" -- stejne to dela rcS pred rebootem
WDG=$(pidof ubia_watchdog)
if [ -n "$WDG" ]; then
	kill -2 $WDG
	sleep 1
	if pidof ubia_watchdog > /dev/null; then
		log "VAROVANI: ubia_watchdog (pid $WDG) na SIGINT nereaguje"
	else
		log "ubia_watchdog ukoncen (pid $WDG)"
	fi
else
	log "ubia_watchdog uz nebezel"
fi

# 3) slusne, at ubia_first zavre deskriptory na SD kartu
APP=$(pidof ubia_first)
if [ -n "$APP" ]; then
	kill -15 $APP
	log "ubia_first (pid $APP): SIGTERM"
	n=0
	while [ $n -lt 5 ] && pidof ubia_first > /dev/null; do
		sleep 1
		n=$((n + 1))
	done

	# 4) natvrdo, kdyz neposlechne
	if pidof ubia_first > /dev/null; then
		kill -9 $APP
		log "ubia_first: SIGKILL"
		sleep 1
	fi
	log "ubia_first ukoncen"
else
	log "ubia_first uz nebezel"
fi

sync

# 5) pojistka: deadman zije v /tmp, ne na karte, aby smel kartu odmountovat
cat > /tmp/hunter_deadman.sh <<'EOF'
#!/bin/sh
# Generovano dev-stop.sh. Rebootuje zarizeni po vyprseni /tmp/hunter_deadline.
trap '' HUP INT
while :; do
	sleep 10
	[ -f /tmp/hunter_hold ] && continue
	DL=$(cat /tmp/hunter_deadline 2>/dev/null)
	case "$DL" in
		''|*[!0-9]*) continue ;;
	esac
	[ "$(date +%s)" -lt "$DL" ] && continue
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] deadman vyprsel, rebootuji" >> /tmp/hunter_dev.log
	sync
	umount -f /tmp/mnt/sdcard 2>/dev/null
	sync
	exec /sbin/reboot -f
done
EOF
chmod +x /tmp/hunter_deadman.sh

if [ -f /tmp/hunter_deadman.pid ]; then
	kill $(cat /tmp/hunter_deadman.pid) 2>/dev/null
	rm -f /tmp/hunter_deadman.pid
fi

rm -f /tmp/hunter_hold
DEADLINE=$(( $(date +%s) + $HOLD ))
echo "$DEADLINE" > /tmp/hunter_deadline

/tmp/hunter_deadman.sh < /dev/null > /dev/null 2>&1 &
echo $! > /tmp/hunter_deadman.pid
log "deadman armovan (pid $!), reboot za $HOLD s (deadline $DEADLINE)"

log "--- zbyvajici procesy ---"
ps | grep -E "ubia|system_call" | grep -v grep

echo
echo "Hotovo. ttyUSB0 i ttyUSB1 jsou volne pro AT testy."
echo "Prodlouzit pauzu : $0 <sekundy>"
echo "Pozastavit pojistku: touch /tmp/hunter_hold   (znovu zapnout: rm /tmp/hunter_hold)"
echo "Zpet do provozu  : ./dev-resume.sh"
