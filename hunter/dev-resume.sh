#!/bin/sh
#
# dev-resume.sh -- navrat z dev-stop.sh do normalniho provozu.
#
# ubia_first se po SIGKILL neda spolehlive nastartovat rucne: drzi si
# stav ISP, MCU (ttyS0) a 4G modulu navazany na boot. Jedina cista cesta
# zpatky je restart -- rcS pak nahodi system_call_daemon, ubia_watchdog
# i ubia_first ve spravnem poradi.
#
# Pouziti:
#   ./dev-resume.sh          reboot hned
#   ./dev-resume.sh -n       jen odzbrojit pojistku, nerebootovat
#

LOG=/tmp/hunter_dev.log

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
	echo "$*"
}

# odzbrojit deadman, at nam nerebootne do zad
if [ -f /tmp/hunter_deadman.pid ]; then
	kill $(cat /tmp/hunter_deadman.pid) 2>/dev/null
	rm -f /tmp/hunter_deadman.pid
fi
rm -f /tmp/hunter_deadline /tmp/hunter_hold
log "deadman odzbrojen"

if [ "$1" = "-n" ]; then
	log "reboot preskocen (-n); zarizeni zustava zastavene bez pojistky"
	exit 0
fi

# stopWdg necham byt -- reboot ho stejne smaze z tmpfs

log "=== dev-resume: rebootuji ==="

# Reboot musi bezet z /tmp, ne z SD karty: umount by pod bezicim
# skriptem odstrelil filesystem, ze ktereho ho shell docitava.
cat > /tmp/hunter_reboot.sh <<'EOF'
#!/bin/sh
sync
umount -f /tmp/mnt/sdcard 2>/dev/null
sync
exec /sbin/reboot -f
EOF
chmod +x /tmp/hunter_reboot.sh

exec /tmp/hunter_reboot.sh
