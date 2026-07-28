#!/usr/bin/env bash
#
# Shuts down this instance after it has been idle for more than
# IDLE_MINUTES minutes, and notifies Telegram right before it does.
# Idle = CPU usage below a threshold AND no recent activity in any
# logged-in session.
#
# Intended to run via root's crontab every minute:
#   * * * * * /home/mike/infra/idle-shutdown.sh
#
# Telegram notification is optional -- if NOTIFY_ENV_FILE doesn't exist,
# notify_telegram() is a no-op. See docs/mvp/server-setup.md for how to
# set it up.
#
# State is tracked across cron runs in STATE_FILE so the idle period can
# span multiple invocations.

set -uo pipefail

IDLE_MINUTES="${IDLE_MINUTES:-30}"
CPU_IDLE_THRESHOLD="${CPU_IDLE_THRESHOLD:-5}"   # max % CPU busy to still count as idle
SESSION_IDLE_THRESHOLD="${SESSION_IDLE_THRESHOLD:-60}"   # seconds since last tty activity to still count as idle
STATE_FILE="${STATE_FILE:-/var/tmp/idle-shutdown.state}"
LOG_FILE="${LOG_FILE:-/var/log/idle-shutdown.log}"
NOTIFY_ENV_FILE="${NOTIFY_ENV_FILE:-/etc/telegram-notify.env}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG_FILE"
}

notify_telegram() {
    [ -f "$NOTIFY_ENV_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$NOTIFY_ENV_FILE"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="🔴 ai-dev-vps auto-shutdown: idle timeout reached" \
        >/dev/null 2>&1
}

cpu_busy_percent() {
    # Sample /proc/stat twice, 1 second apart, and compute % time busy.
    read -r _ u1 n1 s1 i1 w1 irq1 sirq1 _ < /proc/stat
    sleep 1
    read -r _ u2 n2 s2 i2 w2 irq2 sirq2 _ < /proc/stat

    local idle1=$((i1 + w1))
    local idle2=$((i2 + w2))
    local total1=$((u1 + n1 + s1 + i1 + w1 + irq1 + sirq1))
    local total2=$((u2 + n2 + s2 + i2 + w2 + irq2 + sirq2))

    local total_delta=$((total2 - total1))
    local idle_delta=$((idle2 - idle1))

    if [ "$total_delta" -le 0 ]; then
        echo 0
        return
    fi

    echo $(( (100 * (total_delta - idle_delta)) / total_delta ))
}

session_idle_seconds() {
    # Smallest time (in seconds) since last activity across all logged-in
    # ttys, based on device mtime (updated on every keystroke/output).
    local now min_idle=-1 tty mtime idle
    now=$(date +%s)

    while read -r tty; do
        [ -e "/dev/$tty" ] || continue
        mtime=$(stat -c %Y "/dev/$tty" 2>/dev/null) || continue
        idle=$((now - mtime))
        if [ "$min_idle" -eq -1 ] || [ "$idle" -lt "$min_idle" ]; then
            min_idle=$idle
        fi
    done < <(who | awk '{print $2}')

    echo "$min_idle"
}

main() {
    local cpu_busy session_idle now
    cpu_busy=$(cpu_busy_percent)
    session_idle=$(session_idle_seconds)
    now=$(date +%s)

    if [ "$cpu_busy" -gt "$CPU_IDLE_THRESHOLD" ] || { [ "$session_idle" -ge 0 ] && [ "$session_idle" -lt "$SESSION_IDLE_THRESHOLD" ]; }; then
        if [ -f "$STATE_FILE" ]; then
            log "activity detected (cpu=${cpu_busy}% session_idle=${session_idle}s), resetting idle timer"
            rm -f "$STATE_FILE"
        fi
        return
    fi

    if [ ! -f "$STATE_FILE" ]; then
        echo "$now" >"$STATE_FILE"
        log "idle detected (cpu=${cpu_busy}% session_idle=${session_idle}s), starting idle timer"
        return
    fi

    local idle_since idle_elapsed idle_limit
    idle_since=$(cat "$STATE_FILE")
    idle_elapsed=$((now - idle_since))
    idle_limit=$((IDLE_MINUTES * 60))

    if [ "$idle_elapsed" -ge "$idle_limit" ]; then
        log "idle for $((idle_elapsed / 60)) min (>= ${IDLE_MINUTES} min), shutting down"
        notify_telegram
        shutdown -h now
    else
        log "idle for $((idle_elapsed / 60)) min (< ${IDLE_MINUTES} min), waiting"
    fi
}

main
