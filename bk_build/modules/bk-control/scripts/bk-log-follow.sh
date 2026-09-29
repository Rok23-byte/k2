#!/system/bin/sh

PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin
export PATH
umask 022

STATE_DIR=/data/adb/bk-kernel
PID_FILE=$STATE_DIR/bk-log-follow.pid
DMESG_PID_FILE=$STATE_DIR/bk-log-follow.dmesg.pid
LOGCAT_PID_FILE=$STATE_DIR/bk-log-follow.logcat.pid
DMESG_LOG=$STATE_DIR/dmesg.txt
LOGCAT_LOG=$STATE_DIR/logcat.txt
DMESG_LIMIT=16777216

pid_alive()
{
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	[ -d "/proc/$1" ]
}

daemon_running()
{
	pid_alive "$1" || return 1
	case "$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in
		*bk-log-follow.sh*--daemon*) return 0 ;;
	esac
	return 1
}

stop_pid()
{
	pid_alive "$1" || return 0
	kill "$1" 2>/dev/null || true
}

rotate_dmesg()
{
	BK_SIZE=$(wc -c < "$DMESG_LOG" 2>/dev/null || echo 0)
	case "$BK_SIZE" in ''|*[!0-9]*) return 0 ;; esac
	[ "$BK_SIZE" -lt "$DMESG_LIMIT" ] && return 0
	cp -f "$DMESG_LOG" "$DMESG_LOG.1" 2>/dev/null || return 0
	: > "$DMESG_LOG"
}

archive_logs()
{
	BK_STAMP=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo unknown)
	for BK_LOG in "$DMESG_LOG" "$DMESG_LOG.1" "$LOGCAT_LOG" \
		"$LOGCAT_LOG.1" "$LOGCAT_LOG.2" "$LOGCAT_LOG.3" "$LOGCAT_LOG.4"
	do
		[ -s "$BK_LOG" ] || continue
		BK_BASE=${BK_LOG##*/}
		mv -f "$BK_LOG" "$STATE_DIR/kept-$BK_STAMP-$BK_BASE" || return 1
	done
}

mkdir -p "$STATE_DIR" || exit 0

if [ "${1:-}" != --daemon ]; then
	BK_OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
	daemon_running "$BK_OLD_PID" && exit 0
	stop_pid "$(cat "$DMESG_PID_FILE" 2>/dev/null)"
	stop_pid "$(cat "$LOGCAT_PID_FILE" 2>/dev/null)"
	rm -f "$PID_FILE" "$DMESG_PID_FILE" "$LOGCAT_PID_FILE"
	nohup "$0" --daemon </dev/null >> "$STATE_DIR/bk-log-follow.log" 2>&1 &
	exit 0
fi

printf '%s\n' "$$" > "$PID_FILE"
trap 'stop_pid "$(cat "$DMESG_PID_FILE" 2>/dev/null)"; stop_pid "$(cat "$LOGCAT_PID_FILE" 2>/dev/null)"; rm -f "$PID_FILE" "$DMESG_PID_FILE" "$LOGCAT_PID_FILE"; exit 0' EXIT HUP INT TERM

archive_logs || exit 1
printf '===== %s =====\n' "$(date '+%F %T')" >> "$DMESG_LOG"

dmesg -w >> "$DMESG_LOG" 2>&1 &
printf '%s\n' "$!" > "$DMESG_PID_FILE"
logcat -b all -v threadtime -f "$LOGCAT_LOG" -r 16384 -n 4 &
printf '%s\n' "$!" > "$LOGCAT_PID_FILE"

while :; do
	if ! pid_alive "$(cat "$DMESG_PID_FILE" 2>/dev/null)"; then
		dmesg -w >> "$DMESG_LOG" 2>&1 &
		printf '%s\n' "$!" > "$DMESG_PID_FILE"
	fi
	if ! pid_alive "$(cat "$LOGCAT_PID_FILE" 2>/dev/null)"; then
		logcat -b all -v threadtime -f "$LOGCAT_LOG" -r 16384 -n 4 &
		printf '%s\n' "$!" > "$LOGCAT_PID_FILE"
	fi
	rotate_dmesg
	sleep 2
done
