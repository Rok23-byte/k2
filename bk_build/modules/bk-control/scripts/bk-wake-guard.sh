#!/system/bin/sh

PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin
export PATH
umask 077

STATE_DIR=/data/adb/bk-kernel
PID_FILE=$STATE_DIR/bk-wake-guard.pid
ACTIVE_FILE=$STATE_DIR/bk-wake-guard.active
LOG_FILE=$STATE_DIR/bk-wake-guard.log

guard_log()
{
	printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

screen_on()
{
	BK_PANEL=/sys/class/backlight/panel0-backlight
	if [ -r "$BK_PANEL/bl_power" ]; then
		BK_POWER=$(cat "$BK_PANEL/bl_power" 2>/dev/null)
		case "$BK_POWER" in
			0|1) ;;
			*) return 1 ;;
		esac
	fi
	if [ ! -r "$BK_PANEL/brightness" ]; then
		BK_PANEL=/sys/class/backlight/1-0011
	fi
	[ -r "$BK_PANEL/brightness" ] || return 1
	BK_BRIGHTNESS=$(cat "$BK_PANEL/brightness" 2>/dev/null)
	case "$BK_BRIGHTNESS" in ''|*[!0-9]*) return 1 ;; esac
	[ "$BK_BRIGHTNESS" -gt 0 ]
}

touch_asleep()
{
	BK_TOUCH=/sys/class/touch/touch_dev/suspend_state
	[ -r "$BK_TOUCH" ] || return 1
	BK_SUSPEND=$(cat "$BK_TOUCH" 2>/dev/null)
	[ "$BK_SUSPEND" = 1 ]
}

input_ready()
{
	screen_on && ! touch_asleep
}

wait_for_input()
{
	BK_WAIT=$1
	while [ "$BK_WAIT" -gt 0 ]; do
		sleep 1
		input_ready && return 0
		BK_WAIT=$((BK_WAIT - 1))
	done
	return 1
}

kill_named()
{
	BK_KILL_NAME=$1
	BK_KILL_PID=$(pidof "$BK_KILL_NAME" 2>/dev/null) || true
	case "$BK_KILL_PID" in
		''|*[!0-9\ ]*) return 0 ;;
	esac
	kill -9 $BK_KILL_PID 2>/dev/null || true
	guard_log "killed $BK_KILL_NAME pid=$BK_KILL_PID"
}

recover_wake()
{
	[ ! -e "$ACTIVE_FILE" ] || return 0
	: > "$ACTIVE_FILE" || return 0
	trap 'rm -f "$ACTIVE_FILE"' EXIT HUP INT TERM

	[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || return 0
	input_ready && return 0
	wait_for_input 2 && return 0

	# Blank puts the touch IC to sleep. It wakes only after the panel
	# unblank, and that unblank is stuck behind SurfaceFlinger's binder
	# reply. Backlight can stay up while suspend_state is still 1.
	guard_log "touch still asleep; restarting surfaceflinger"
	kill_named surfaceflinger
	wait_for_input 4 && {
		guard_log "touch recovered after surfaceflinger restart"
		return 0
	}

	guard_log "touch still asleep; restarting system_server"
	kill_named system_server
}

find_power_event()
{
	BK_INPUT_DIR=""
	for BK_INPUT in /sys/class/input/input*; do
		[ "$(cat "$BK_INPUT/name" 2>/dev/null)" = qpnp_pon ] || continue
		BK_INPUT_DIR=$BK_INPUT
		break
	done
	[ -n "$BK_INPUT_DIR" ] || return 1
	for BK_EVENT in "$BK_INPUT_DIR"/event*; do
		[ -e "$BK_EVENT" ] || continue
		BK_NAME=${BK_EVENT##*/}
		case "$BK_NAME" in
			event*[!0-9]*) continue ;;
			event*)
				echo "/dev/input/$BK_NAME"
				return 0
				;;
		esac
	done
	return 1
}

daemon_running()
{
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	[ -r "/proc/$1/cmdline" ] || return 1
	case "$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in
		*bk-wake-guard.sh*--daemon*) return 0 ;;
	esac
	return 1
}

mkdir -p "$STATE_DIR" || exit 0

if [ "${1:-}" != --daemon ]; then
	BK_OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
	daemon_running "$BK_OLD_PID" && exit 0
	rm -f "$PID_FILE" "$ACTIVE_FILE"
	nohup "$0" --daemon </dev/null >> "$LOG_FILE" 2>&1 &
	exit 0
fi

printf '%s\n' "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE" "$ACTIVE_FILE"; exit 0' EXIT HUP INT TERM
guard_log "started"

BK_LISTENING=""
while :; do
	POWER_EVENT=$(find_power_event) || POWER_EVENT=""
	if [ ! -r "$POWER_EVENT" ]; then
		sleep 2
		continue
	fi
	if [ "$POWER_EVENT" != "$BK_LISTENING" ]; then
		BK_LISTENING=$POWER_EVENT
		guard_log "listening $POWER_EVENT"
	fi
	getevent -l "$POWER_EVENT" 2>/dev/null | while IFS= read -r BK_EVENT; do
		case "$BK_EVENT" in
			*EV_KEY*KEY_POWER*DOWN*|*' 0001 0074 00000001'*)
				if ! input_ready; then
					recover_wake &
				fi
				;;
		esac
	done
	sleep 2
done
