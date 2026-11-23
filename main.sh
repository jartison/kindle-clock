#!/bin/sh

# ==========================================
# Kindle Clock - Prototype v0.1
# Kindle 7 / WP63GW
# ==========================================

KINDLE_CLOCK_HOME=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log() {
    local level
    local message

    level="$1"
    shift
    message="$*"

    printf '[%s] [%s] %s\n' \
        "$(TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S')" \
        "$level" "$message" >&2
}

debug() {
    [ "$VERBOSE" -eq 1 ] || return 0

    log DEBUG "$@"
}

info() {
    log INFO "$@"
}

warning() {
    log WARNING "$@"
}

error() {
    log ERROR "$@"
}

critical() {
    log CRITICAL "$@"
}

parse_arg() {
    local name
    local default_value
    local value

    name="$1"
    default_value="$2"
    shift 2

    value="$default_value"

    while [ "$#" -gt 0 ]; do
        if [ "$1" = "$name" ]; then
            if [ "$#" -lt 2 ]; then
                error "Missing value for argument: $name"
                return 1
            fi

            value="$2"
            break
        fi

        shift
    done

    printf '%s\n' "$value"
    return 0
}

get_screen_size() {
    fbset -s | awk '/geometry/ {print $2, $3; exit}'
}

get_rtc_wakealarm() {
    local rtc_wakealarm
    local rtc_dir
    local wakeup_file
    local wakeup_state

    rtc_wakealarm=""

    for rtc_dir in /sys/class/rtc/rtc*; do
        [ -d "$rtc_dir" ] || continue

        if [ -e "$rtc_dir/wakealarm" ]; then

            wakeup_file="$rtc_dir/device/power/wakeup"
            wakeup_state="unknown"

            if [ -r "$wakeup_file" ]; then
                wakeup_state=$(cat "$wakeup_file")
            fi

            debug "RTC: $rtc_dir wakeup=$wakeup_state"

            if [ "$wakeup_state" = "enabled" ]; then
                rtc_wakealarm="$rtc_dir/wakealarm"
                break
            fi
        fi
    done

    printf '%s\n' "$rtc_wakealarm"
    return 0
}

get_translations() {
    local translations_file

    translations_file="$KINDLE_CLOCK_HOME/languages/$LANGUAGE.txt"

    if ! cat "$translations_file"; then
        error "Failed to read $translations_file"
        return 1
    fi

    return 0
}

get_wttr_language() {
    local wttr_languages_file

    wttr_languages_file="$KINDLE_CLOCK_HOME/config/wttr-languages.txt"

    awk -F= -v key="$LANGUAGE" '
        $1 == key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$wttr_languages_file"
}

get_screensaver_state() {
    local prop

    if ! prop=$(lipc-get-prop com.lab126.powerd preventScreenSaver); then
        error "Failed to get prop: preventScreenSaver."
        return 1
    fi

    if [ "$prop" = "0" ]; then
        printf '%s\n' "1"
    elif [ "$prop" = "1" ]; then
        printf '%s\n' "0"
    else
        error "Invalid prop value: prevetScreenSaver=$prop."
        return 1
    fi

    return 0
}

set_screensaver_state() {
    local state
    local prop

    state="$1"

    if [ "$state" = "0" ]; then
        prop="1"
    elif [ "$state" = "1" ]; then
        prop="0"
    else
        error "Invalid state value: screensaver_state=$state"
        return 1
    fi

    if ! lipc-set-prop com.lab126.powerd preventScreenSaver "$prop"; then
        error "Failed to set prop: preventScreenSaver=$prop"
        return 1
    fi

    return 0
}

get_wireless_state() {
    local prop

    if ! prop=$(lipc-get-prop com.lab126.cmd wirelessEnable); then
        error "Failed to get prop: wirelessEnable."
        return 1
    fi

    if [ "$prop" = "0" ]; then
        printf '%s\n' "0"
    elif [ "$prop" = "1" ]; then
        printf '%s\n' "1"
    else
        error "Invalid prop value: wirelessEnable=$prop."
        return 1
    fi

    return 0
}

set_wireless_state() {
    local state
    local prop

    state="$1"

    if [ "$state" = "0" ]; then
        prop="0"
    elif [ "$state" = "1" ]; then
        prop="1"
    else
        error "Invalid state value: wireless_state=$state."
        return 1
    fi

    if ! lipc-set-prop com.lab126.cmd wirelessEnable "$prop"; then
        error "Failed to set prop: wirelessEnable=$prop."
        return 1
    fi

    return 0
}

update_time() {
    ntpdate -s "$NTP_SERVER"
}

update_weather() {
    local weather

    if ! weather=$(curl -s -f -m "$WEATHER_UPDATE_TIMEOUT" "https://wttr.in/$WEATHER_LOCATION?format=%C+%t&lang=$WEATHER_LANGUAGE"); then
        error "Failed to get weather."
        return 1
    fi

    WEATHER="$weather"

    return 0
}

ensure_wireless_connection() {
    local reconnect_count
    local connect_at
    local current
    local cm_state

    debug "Ensuring wireless connection (max reconnects: $WIRELESS_RECONNECT_COUNT, connect timeout: $WIRELESS_CONNECT_TIMEOUT)."

    reconnect_count=0

    while :; do
        connect_at=$(date +%s)

        while :; do
            if ! cm_state=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null); then
                warning "Failed to get prop: cmState. Using UNKNOWN."
                cm_state="UNKNOWN"
            fi

            debug "cm_state=$cm_state"

            if [ "$cm_state" = "CONNECTED" ]; then
                return 0
            fi

            current=$(date +%s)

            if [ "$((current - connect_at))" -ge "$WIRELESS_CONNECT_TIMEOUT" ]; then
                break
            fi

            sleep 1
        done

        if [ "$cm_state" != "PENDING" ]; then
            break
        fi

        if [ "$reconnect_count" -ge "$WIRELESS_RECONNECT_COUNT" ]; then
            break
        fi

        reconnect_count=$((reconnect_count + 1))

        debug "Reconnect attempt: $reconnect_count/$WIRELESS_RECONNECT_COUNT"

        if ! wpa_cli -i wlan0 reconnect >/dev/null 2>&1; then
            warning "Failed to reconnect to wireless."
        fi

    done

    error "Wireless connection not established."
    return 1
}

run_network_tasks() {
    local current
    local time_update_elapsed
    local time_update_due
    local time_update_needed
    local weather_update_elapsed
    local weather_update_due
    local weather_update_needed
    local status

    current=$(date +%s)

    time_update_elapsed=$((current - TIME_UPDATE_AT))
    weather_update_elapsed=$((current - WEATHER_UPDATE_AT))

    # debug "Time update interval: $TIME_UPDATE_INTERVAL. Elapsed: $time_update_elapsed."
    # debug "Weather update interval: $WEATHER_UPDATE_INTERVAL. Elapsed: $weather_update_elapsed."

    time_update_due=$((time_update_elapsed >= TIME_UPDATE_INTERVAL))
    weather_update_due=$((weather_update_elapsed >= WEATHER_UPDATE_INTERVAL))

    # debug "Enable time update: $ENABLE_TIME_UPDATE. Time update due: $time_update_due."
    # debug "Enable weather: $ENABLE_WEATHER. Weather update due: $weather_update_due."

    time_update_needed=$((ENABLE_TIME_UPDATE && time_update_due))
    weather_update_needed=$((ENABLE_WEATHER && weather_update_due))

    # debug "Time update needed: $time_update_needed. Weather update needed: $weather_update_needed."

    if [ "$time_update_needed" -eq 1 ] || [ "$weather_update_needed" -eq 1 ]; then 
        if [ "$time_update_needed" -eq 1 ]; then
            TIME_UPDATE_AT="$current"
        fi

        if [ "$weather_update_needed" -eq 1 ]; then
            WEATHER_UPDATE_AT="$current"
        fi

        if ! set_wireless_state "1"; then
            error "Failed to set wireless state: 1"
            return 1
        fi

        status=0

        if ! ensure_wireless_connection; then
            error "Failed to ensure wireless connection."
            status=1
        else
            if [ "$time_update_needed" -eq 1 ]; then
                debug "Time updating."
                if update_time; then
                    debug "Time updated."
                else
                    warning "Failed to update time."
                fi
            fi

            if [ "$weather_update_needed" -eq 1 ]; then
                debug "Weather updating."
                if update_weather; then
                    debug "Weather updated."
                else
                    warning "Failed to update weather."
                fi
            fi
        fi

        if [ "$KEEP_WIRELESS_ENABLED" -ne 1 ]; then
            if ! set_wireless_state "0"; then
                warning "Failed to set wireless state: 0"
            fi
        fi

        return "$status"
    fi

    return 0
}

to_weekday_key() {
    case "$1" in
        0) printf '%s\n' "SUNDAY" ;;
        1) printf '%s\n' "MONDAY" ;;
        2) printf '%s\n' "TUESDAY" ;;
        3) printf '%s\n' "WEDNESDAY" ;;
        4) printf '%s\n' "THURSDAY" ;;
        5) printf '%s\n' "FRIDAY" ;;
        6) printf '%s\n' "SATURDAY" ;;
        *) return 1 ;;
    esac
}

translate() {
    local code
    local translation

    code="$1"

    translation=$(printf '%s\n' "$TRANSLATIONS" | awk -F= -v key="$code" '
        $1 == key {
            sub(/^[^=]*=/, "")
            print
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ')

    if [ $? -eq 0 ]; then
        printf '%s\n' "$translation"
    else
        printf '%s\n' "$code"
    fi

    return 0
}

fbink() {
    "$KINDLE_CLOCK_HOME/bin/fbink" "$@" >/dev/null 2>&1
}

flash_screen() {
    fbink -w -f -s
}

refresh_screen() {
    fbink -w -s
}

before_draw() {
    :
}

draw() {
    local hour
    local minute
    local weekday
    local day
    local info
    local time_font_size_max
    local time_font_size
    local info_font_size_max
    local info_font_size
    local hour_top
    local minute_top
    local info_top

    set -- $(TZ="$TIMEZONE" date '+%H %M %w %-d')

    hour=$1
    minute=$2
    weekday=$(translate $(to_weekday_key "$3"))
    day=$4
    info="$weekday $day $WEATHER"

    debug "hour=$hour, minute=$minute, info=$info"

    time_font_size_max=$((SCREEN_WIDTH < SCREEN_HEIGHT / 2 ? SCREEN_WIDTH : SCREEN_HEIGHT / 2))
    time_font_size=$((time_font_size_max * TIME_FONT_SCALE / 100))

    # debug "time_font_size_max=$time_font_size_max, time_font_size=$time_font_size"

    info_font_size_max=$((SCREEN_WIDTH < SCREEN_HEIGHT / 20 ? SCREEN_WIDTH : SCREEN_HEIGHT / 20))
    info_font_size=$((info_font_size_max * INFO_FONT_SCALE / 100))

    # debug "info_font_size_max=$info_font_size_max, info_font_size=$info_font_size"

    hour_top=$(((SCREEN_HEIGHT / 2 - time_font_size_max) * 2 / 3 + (time_font_size_max - time_font_size) / 2))
    minute_top=$((SCREEN_HEIGHT / 2 + (SCREEN_HEIGHT / 2 - time_font_size_max) / 3 + (time_font_size_max - time_font_size) / 2))
    info_top=$((SCREEN_HEIGHT - info_font_size_max + (info_font_size_max - info_font_size) / 2))

    # debug "hour_top=$hour_top, minute_top=$minute_top, info_top=$info_top"

    if ! fbink -b -c; then
        error "Failed to clear framebuffer."
        return 1
    fi

    if ! fbink -b \
        -t "regular=$TIME_FONT,px=$time_font_size,top=$hour_top,left=0,right=0" \
        -m "$hour"; then
        error "Failed to draw hour."
        return 1
    fi

    if ! fbink -b \
        -t "regular=$TIME_FONT,px=$time_font_size,top=$minute_top,left=0,right=0" \
        -m "$minute"; then
        error "Failed to draw minute."
        return 1
    fi

    if ! fbink -b \
        -t "regular=$INFO_FONT,px=$info_font_size,top=$info_top,left=0,right=0" \
        -m "$info"; then
        error "Failed to draw info."
        return 1
    fi

    return 0
}

after_draw() {
    if ! run_network_tasks; then
        warning "Failed to run network tasks."
    fi
}

suspend() {
    local current
    local suspend_seconds
    local expected_resume_at
    local resume_at

    current=$(date +%s)
    suspend_seconds=$((SUSPEND_SECONDS - current % SUSPEND_SECONDS))

    if [ "$suspend_seconds" -lt 5 ]; then
        suspend_seconds=$((suspend_seconds + 60))
    fi

    expected_resume_at=$((current + suspend_seconds))

    # debug "Resume in $suspend_seconds seconds."

    if ! echo 0 > "$RTC_WAKEALARM"; then
        error "Failed to clear RTC alarm."
        return 1
    fi

    if ! echo "+$suspend_seconds" > "$RTC_WAKEALARM"; then
        error "Failed to setup RTC alarm."
        return 1
    fi

    if ! echo mem > /sys/power/state; then
        error "Failed to suspend memory."
        return 1
    fi

    resume_at=$(date +%s)
    debug "Resumed at $resume_at. Expected resume at $expected_resume_at."

    if [ "$resume_at" -lt "$((expected_resume_at - RESUME_TOLERANCE))" ]; then
        warning "Unexpected early resume detected."
        return 2
    fi

    return 0
}

run() {
    local cycle
    local suspend_status

    cycle=0

    while [ "$MAX_CYCLES" -le 0 ] || [ "$cycle" -lt "$MAX_CYCLES" ]; do
        debug "========== Cycle $cycle =========="

        if ! before_draw; then
            warning "Failed to call before_draw."
        fi

        if ! draw; then
            warning "Failed to draw."
        fi

        if ! refresh_screen; then
            warning "Failed to refresh screen."
        fi

        if [ $((cycle % SCREEN_FLASH_INTERVAL)) -eq 0 ]; then
            if ! flash_screen; then
                warning "Failed to flash screen."
            fi
        fi

        if ! after_draw; then
            warning "Failed to call after_draw."
        fi

        cycle=$((cycle + 1))

        if [ "$MAX_CYCLES" -le 0 ] || [ "$cycle" -lt "$MAX_CYCLES" ]; then
            suspend
            suspend_status=$?

            if [ "$suspend_status" -eq 2 ]; then
                break
            elif [ "$suspend_status" -ne 0 ]; then
                return 1
            fi
        fi
    done

    return 0
}

setup() {
    local translations
    local weather_language
    local rtc_wakealarm
    local screensaver_state
    local wireless_state

    if ! translations=$(get_translations); then
        error "Failed to get translations."
        return 1
    fi
    TRANSLATIONS="$translations"

    if ! weather_language=$(get_wttr_language); then
        error "Failed to get WTTR language."
        return 1
    fi
    debug "Weather language: $weather_language"
    WEATHER_LANGUAGE="$weather_language"

    if ! set -- $(get_screen_size); then
        error "Failed to get screen size."
        return 1
    fi
    debug "Screen size: $2 * $1"
    SCREEN_WIDTH="$1"
    SCREEN_HEIGHT="$2"

    if ! rtc_wakealarm=$(get_rtc_wakealarm); then
        error "Failed to get RTC wakealarm."
        return 1
    fi 

    debug "RTC wakealarm: $rtc_wakealarm"
    RTC_WAKEALARM="$rtc_wakealarm"

    # Save screensaver state
    if ! screensaver_state=$(get_screensaver_state); then
        error "Failed to get screensaver state."
        return 1
    fi
    debug "Screensaver state: $screensaver_state"
    SCREENSAVER_STATE="$screensaver_state"

    if ! set_screensaver_state "0"; then
        error "Failed to set screensaver state: 0"
        return 1
    fi

    # Save wireless state
    if ! wireless_state=$(get_wireless_state); then
        error "Failed to get wireless state"
        return 1
    fi
    debug "Wireless state: $wireless_state"
    WIRELESS_STATE="$wireless_state"

    TIME_UPDATE_AT=0

    WEATHER_UPDATE_AT=0
    WEATHER="--"

    return 0
}

on_exit() {
    # Restore screenersaver state
    if [ -n "$SCREENSAVER_STATE" ]; then
        if ! set_screensaver_state "$SCREENSAVER_STATE"; then
            warning "Failed to set screen state: $SCREENSAVER_STATE."
        fi
    fi

    # Reset wireless state
    if [ -n "$WIRELESS_STATE" ]; then
        if ! set_wireless_state "$WIRELESS_STATE"; then
            warning "Failed to set wireless state: $WIRELESS_STATE."
        fi
    fi
}

main () {
    VERBOSE=$(parse_arg "--verbose" "0" "$@") || return 1
    DELAY=$(parse_arg "--delay" "0" "$@") || return 1
    LANGUAGE=$(parse_arg "--language" "en" "$@") || return 1

    MAX_CYCLES=$(parse_arg "--max-cycles" "-1" "$@") || return 1
    SUSPEND_SECONDS=$(parse_arg "--suspend-seconds" "60" "$@") || return 1
    RESUME_TOLERANCE=$(parse_arg "--resume-tolerance" "1" "$@") || return 1
    SCREEN_FLASH_INTERVAL=$(parse_arg "--screen-flash-interval" "30" "$@") || return 1

    TIMEZONE=$(parse_arg "--timezone" "UTC-0" "$@") || return 1
    TIME_FONT=$(parse_arg "--time-font" "$KINDLE_CLOCK_HOME/fonts/digital-7 (mono).ttf" "$@") || return 1
    TIME_FONT_SCALE=$(parse_arg "--time-font-scale" "90" "$@") || return 1
    INFO_FONT=$(parse_arg "--info-font" "$KINDLE_CLOCK_HOME/fonts/unifont-18.0.01.otf" "$@") || return 1
    INFO_FONT_SCALE=$(parse_arg "--info-font-scale" "80" "$@") || return 1

    KEEP_WIRELESS_ENABLED=$(parse_arg "--keep-wireless-enabled" "1" "$@") || return 1
    WIRELESS_CONNECT_TIMEOUT=$(parse_arg "--wireless-connect-timeout" "30" "$@") || return 1
    WIRELESS_RECONNECT_COUNT=$(parse_arg "--wireless-reconnect-count" "2" "$@") || return 1

    ENABLE_TIME_UPDATE=$(parse_arg "--enable-time-update" "1" "$@") || return 1
    TIME_UPDATE_INTERVAL=$(parse_arg "--time-update-interval" "86400" "$@") || return 1
    NTP_SERVER=$(parse_arg "--ntp-server" "pool.ntp.org" "$@") || return 1

    ENABLE_WEATHER=$(parse_arg "--enable-weather-update" "1" "$@") || return 1
    WEATHER_UPDATE_INTERVAL=$(parse_arg "--weather-update-interval" "3600" "$@") || return 1
    WEATHER_UPDATE_TIMEOUT=$(parse_arg "--weather-update-timeout" "30" "$@") || return 1
    WEATHER_LOCATION=$(parse_arg "--weather-location" "" "$@") || return 1

    trap 'on_exit' EXIT

    if ! setup; then
        error "Failed to setup."
        return 1
    fi

    sleep "$DELAY"

    if ! run; then
        error "Failed to run."
        return 1
    fi
}

main "$@"
exit $?