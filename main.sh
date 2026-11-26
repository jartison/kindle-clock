#!/bin/sh

# ==========================================
# Kindle Clock - Prototype v0.1.1
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

get_prevent_screensaver() {
    lipc-get-prop com.lab126.powerd preventScreenSaver
}

set_prevent_screensaver() {
    lipc-set-prop com.lab126.powerd preventScreenSaver "$1"
}

get_wireless_enable() {
    lipc-get-prop com.lab126.cmd wirelessEnable
}

set_wireless_enable() {
    lipc-set-prop com.lab126.cmd wirelessEnable "$1"
}

get_battery_level() {
    lipc-get-prop com.lab126.powerd battLevel
}

get_is_charging() {
    lipc-get-prop com.lab126.powerd isCharging
}

get_epdc_mode() {
    lipc-get-prop com.lab126.winmgr epdcMode
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

        if ! set_wireless_enable "1"; then
            error "Failed to set wireless enable: 1"
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
            if ! set_wireless_enable "0"; then
                warning "Failed to set wireless enable: 0"
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

refresh_screen() {
    local epdc_mode
    local flash_option
    local nightmode_option

    flash_option=""

    if [ "$1" = "1" ]; then
        flash_option="-f"
    fi

    nightmode_option=""

    case "$DISPLAY_MODE" in
        light)
            ;;
        dark)
            nightmode_option="-H"
            ;;
        system)
            if ! epdc_mode=$(get_epdc_mode); then
                warning "Failed to get epdc mode."
            elif [ "$epdc_mode" == "Y8INV" ]; then
                    nightmode_option="-H"
            fi
            ;;
    esac

    # debug "flash_option=$flash_option, nightmode_option=$nightmode_option"

    fbink $flash_option $nightmode_option -w -s
}

before_draw() {
    :
}

draw() {
    local is_charging
    local battery_level
    local battery_image
    local hour_format
    local hour
    local minute
    local weekday
    local day
    local info
    local status_size
    local time_size
    local info_size
    local status_image_size_max
    local status_image_size
    local status_font_size_max
    local status_font_size
    local time_font_size_max
    local time_font_size
    local info_font_size_max
    local info_font_size

    if ! is_charging=$(get_is_charging); then
        warning "Failed to get is_charging."
        is_charging=""
    fi

    if ! battery_level=$(get_battery_level); then
        warning "Failed to get battery level."
        battery_level=""
    fi
    
    if [ "$USE_24_HOUR" -eq 1 ]; then
        hour_format='%H'
    else
        hour_format='%I'
    fi

    set -- $(TZ="$TIMEZONE" date "+$hour_format %M %w %-d")

    hour=$1
    minute=$2
    weekday=$3
    day=$4

    debug "is_charging=$is_charging, bettery_level=$battery_level, hour=$hour, minute=$minute, weekday=$weekday, day=$day, weather=$WEATHER"

    battery_image="$BATTERY_IMAGE_UNKNOWN"

    if [ "$is_charging" = "1" ]; then
        battery_image="$BATTERY_IMAGE_CHARGING"
    elif [ "$is_charging" = "0" ]; then
        if [ -n "$battery_level" ]; then
            if [ "$battery_level" -le 10 ]; then
                battery_image="$BATTERY_IMAGE_WARNING"
            elif [ "$battery_level" -le 33 ]; then
                battery_image="$BATTERY_IMAGE_LOW"
            elif [ "$battery_level" -le 66 ]; then
                battery_image="$BATTERY_IMAGE_MEDIUM"
            else
                battery_image="$BATTERY_IMAGE_FULL"
            fi
        fi
    fi

    info="$(translate "$(to_weekday_key "$weekday")") $day"

    if [ "$ENABLE_WEATHER" = "1" ]; then
        info="$info ${WEATHER:---}"
    fi

    status_size=$((SCREEN_HEIGHT * STATUS_SIZE_FACTOR / (STATUS_SIZE_FACTOR + 2 * TIME_SIZE_FACTOR + INFO_SIZE_FACTOR)))
    time_size=$((SCREEN_HEIGHT * TIME_SIZE_FACTOR / (STATUS_SIZE_FACTOR + 2 * TIME_SIZE_FACTOR + INFO_SIZE_FACTOR)))
    info_size=$((SCREEN_HEIGHT * INFO_SIZE_FACTOR / (STATUS_SIZE_FACTOR + 2 * TIME_SIZE_FACTOR + INFO_SIZE_FACTOR)))

    # debug "status_size=$status_size, time_size=$time_size, info_size=$info_size"

    status_image_size_max="$status_size"
    status_image_size=$((status_image_size_max * STATUS_IMAGE_SIZE_SCALE / 100))

    # debug "status_image_size_max=$status_image_size_max, status_image_size=$status_image_size"

    status_font_size_max="$status_size"
    status_font_size=$((status_font_size_max * STATUS_FONT_SIZE_SCALE / 100))

    # debug "status_font_size_max=$status_font_size_max, status_font_size=$status_font_size"

    time_font_size_max="$time_size"
    time_font_size=$((time_font_size_max * TIME_FONT_SIZE_SCALE / 100))

    # debug "time_font_size_max=$time_font_size_max, time_font_size=$time_font_size"

    info_font_size_max="$info_size"
    info_font_size=$((info_font_size_max * INFO_FONT_SIZE_SCALE / 100))

    # debug "info_font_size_max=$info_font_size_max, info_font_size=$info_font_size"

    if ! fbink -b -c; then
        error "Failed to clear framebuffer."
        return 1
    fi

    if ! fbink -b \
        -g "file=$battery_image,x=$(((status_font_size_max - status_image_size) / 2)),y=$(((status_font_size_max - status_image_size) / 2)),w=$status_image_size,h=$status_image_size" ; then
        error "Failed to draw battery icon."
        return 1
    fi

    if ! fbink -b \
        -t "regular=$STATUS_FONT,px=$status_font_size,bottom=$((SCREEN_HEIGHT - status_font_size_max)),left=$status_font_size_max" \
        -M "${battery_level:---}%"; then
        error "Failed to draw battery level."
        return 1
    fi

    # debug "Hour: top=$status_font_size_max, bottom=$((SCREE_HEIGHT- (status_font_size_max + time_font_size_max * 2 * TIME_LAYOUT_DENSITY / 100 + time_font_size * (100 - 2 * TIME_LAYOUT_DENSITY) / 100)))"

    if ! fbink -b \
        -t "regular=$TIME_FONT,px=$time_font_size,top=$status_font_size_max,bottom=$((SCREEN_HEIGHT - (status_font_size_max + time_font_size_max * 2 * TIME_LAYOUT_DENSITY / 100 + time_font_size * (100 - 2 * TIME_LAYOUT_DENSITY) / 100)))" \
        -mM "$hour"; then
        error "Failed to draw hour."
        return 1
    fi

    # debug "Minute: top=$((SCREEN_HEIGHT - (info_font_size_max + time_font_size_max * 2 * TIME_LAYOUT_DENSITY / 100 + time_font_size * (100 - 2 * TIME_LAYOUT_DENSITY) / 100))), bottom=$info_font_size_max"

    if ! fbink -b \
        -t "regular=$TIME_FONT,px=$time_font_size,top=$((SCREEN_HEIGHT - (info_font_size_max + time_font_size_max * 2 * TIME_LAYOUT_DENSITY / 100 + time_font_size * (100 - 2 * TIME_LAYOUT_DENSITY) / 100))),bottom=$info_font_size_max" \
        -mM "$minute"; then
        error "Failed to draw minute."
        return 1
    fi

    if ! fbink -b \
        -t "regular=$INFO_FONT,px=$info_font_size,top=$((SCREEN_HEIGHT - info_font_size_max))" \
        -mM "$info"; then
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

    if [ -n "$RTC_WAKEALARM" ]; then
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
    else
        sleep "$suspend_seconds"
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
    local flash

    cycle=0

    while [ "$MAX_CYCLES" -le 0 ] || [ "$cycle" -lt "$MAX_CYCLES" ]; do
        debug "========== Cycle $cycle =========="

        if ! before_draw; then
            warning "Failed to call before_draw."
        fi

        if ! draw; then
            warning "Failed to draw."
        fi

        if [ $((cycle % SCREEN_FLASH_INTERVAL)) -eq 0 ]; then
            flash="1"
        else
            flash="0"
        fi

        debug "Screen refreshing. Flash: $flash."

        if ! refresh_screen "$flash"; then
            warning "Failed to refresh screen."
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

parse_args() {
    if ! VERBOSE=$(parse_arg "--verbose" "0" "$@"); then
        error "Failed to parse arg: --verbose."
        VERBOSE=""
        return 1
    fi

    if ! DELAY=$(parse_arg "--delay" "0" "$@"); then
        error "Failed to parse arg: --delay."
        DELAY=""
        return 1
    fi

    if ! LANGUAGE=$(parse_arg "--language" "en" "$@"); then
        error "Failed to parse arg: --language."
        LANGUAGE=""
        return 1
    fi

    if ! MAX_CYCLES=$(parse_arg "--max-cycles" "-1" "$@"); then
        error "Failed to parse arg: --max-cycles."
        MAX_CYCLES=""
        return 1
    fi

    if ! SUSPEND_SECONDS=$(parse_arg "--suspend-seconds" "60" "$@"); then
        error "Failed to parse arg: --suspend-seconds."
        SUSPEND_SECONDS=""
        return 1
    fi

    if ! RESUME_TOLERANCE=$(parse_arg "--resume-tolerance" "1" "$@"); then
        error "Failed to parse arg: --resume-tolerance."
        RESUME_TOLERANCE=""
        return 1
    fi

    if ! SCREEN_FLASH_INTERVAL=$(parse_arg "--screen-flash-interval" "30" "$@"); then
        error "Failed to parse arg: --screen-flash-interval."
        SCREEN_FLASH_INTERVAL=""
        return 1
    fi

    if ! DISPLAY_MODE=$(parse_arg "--display-mode" "system" "$@"); then
        error "Failed to parse arg: --display-mode."
        DISPLAY_MODE=""
        return 1
    fi

    if ! TIMEZONE=$(parse_arg "--timezone" "UTC-0" "$@"); then
        error "Failed to parse arg: --timezone."
        TIMEZONE=""
        return 1
    fi

    if ! USE_24_HOUR=$(parse_arg "--use-24-hour" "1" "$@"); then
        error "Failed to parse arg: --use-24-hour."
        USE_24_HOUR=""
        return 1
    fi

    if ! STATUS_FONT=$(parse_arg "--status-font" "$KINDLE_CLOCK_HOME/fonts/Inter_24pt-Regular.ttf" "$@"); then
        error "Failed to parse arg: --status-font."
        STATUS_FONT=""
        return 1
    fi

    if ! TIME_FONT=$(parse_arg "--time-font" "$KINDLE_CLOCK_HOME/fonts/digital-7 (mono).ttf" "$@"); then
        error "Failed to parse arg: --time-font."
        TIME_FONT=""
        return 1
    fi

    if ! INFO_FONT=$(parse_arg "--info-font" "$KINDLE_CLOCK_HOME/fonts/NotoSans-Regular.ttf" "$@"); then
        error "Failed to parse arg: --info-font."
        INFO_FONT=""
        return 1
    fi

    if ! STATUS_SIZE_FACTOR=$(parse_arg "--status-size-factor" "1" "$@"); then
        error "Failed to parse arg: --status-size-factor."
        STATUS_SIZE_FACTOR=""
        return 1
    fi

    if ! TIME_SIZE_FACTOR=$(parse_arg "--time-size-factor" "9" "$@"); then
        error "Failed to parse arg: --time-size-factor."
        TIME_SIZE_FACTOR=""
        return 1
    fi

    if ! INFO_SIZE_FACTOR=$(parse_arg "--info-size-factor" "1" "$@"); then
        error "Failed to parse arg: --info-size-factor."
        INFO_SIZE_FACTOR=""
        return 1
    fi

    if ! TIME_LAYOUT_DENSITY=$(parse_arg "--time-layout-density" "66" "$@"); then
        error "Failed to parse arg: --time-layout-density."
        TIME_LAYOUT_DENSITY=""
        return 1
    fi

    if ! STATUS_IMAGE_SIZE_SCALE=$(parse_arg "--status-image-size-scale" "75" "$@"); then
        error "Failed to parse arg: --status-image-size-scale."
        STATUS_IMAGE_SIZE_SCALE=""
        return 1
    fi

    if ! STATUS_FONT_SIZE_SCALE=$(parse_arg "--status-font-size-scale" "60" "$@"); then
        error "Failed to parse arg: --status-font-size-scale."
        STATUS_FONT_SIZE_SCALE=""
        return 1
    fi

    if ! TIME_FONT_SIZE_SCALE=$(parse_arg "--time-font-size-scale" "90" "$@"); then
        error "Failed to parse arg: --time-font-size-scale."
        TIME_FONT_SIZE_SCALE=""
        return 1
    fi

    if ! INFO_FONT_SIZE_SCALE=$(parse_arg "--info-font-size-scale" "90" "$@"); then
        error "Failed to parse arg: --info-font-size-scale."
        INFO_FONT_SIZE_SCALE=""
        return 1
    fi

    if ! BATTERY_IMAGE_UNKNOWN=$(parse_arg "--battery-image-unknown" "$KINDLE_CLOCK_HOME/images/battery-unknown.png" "$@"); then
        error "Failed to parse arg: --battery-image-unknown."
        BATTERY_IMAGE_UNKNOWN=""
        return 1
    fi

    if ! BATTERY_IMAGE_CHARGING=$(parse_arg "--battery-image-charging" "$KINDLE_CLOCK_HOME/images/battery-charging.png" "$@"); then
        error "Failed to parse arg: --battery-image-charging."
        BATTERY_IMAGE_CHARGING=""
        return 1
    fi

    if ! BATTERY_IMAGE_FULL=$(parse_arg "--battery-image-full" "$KINDLE_CLOCK_HOME/images/battery-full.png" "$@"); then
        error "Failed to parse arg: --battery-image-full."
        BATTERY_IMAGE_FULL=""
        return 1
    fi

    if ! BATTERY_IMAGE_MEDIUM=$(parse_arg "--battery-image-medium" "$KINDLE_CLOCK_HOME/images/battery-medium.png" "$@"); then
        error "Failed to parse arg: --battery-image-medium."
        BATTERY_IMAGE_MEDIUM=""
        return 1
    fi

    if ! BATTERY_IMAGE_LOW=$(parse_arg "--battery-image-low" "$KINDLE_CLOCK_HOME/images/battery-low.png" "$@"); then
        error "Failed to parse arg: --battery-image-low."
        BATTERY_IMAGE_LOW=""
        return 1
    fi

    if ! BATTERY_IMAGE_WARNING=$(parse_arg "--battery-image-warning" "$KINDLE_CLOCK_HOME/images/battery-warning.png" "$@"); then
        error "Failed to parse arg: --battery-image-warning."
        BATTERY_IMAGE_WARNING=""
        return 1
    fi

    if ! KEEP_WIRELESS_ENABLED=$(parse_arg "--keep-wireless-enabled" "1" "$@"); then
        error "Failed to parse arg: --keep-wireless-enabled."
        KEEP_WIRELESS_ENABLED=""
        return 1
    fi

    if ! WIRELESS_CONNECT_TIMEOUT=$(parse_arg "--wireless-connect-timeout" "30" "$@"); then
        error "Failed to parse arg: --wireless-connect-timeout."
        WIRELESS_CONNECT_TIMEOUT=""
        return 1
    fi

    if ! WIRELESS_RECONNECT_COUNT=$(parse_arg "--wireless-reconnect-count" "2" "$@"); then
        error "Failed to parse arg: --wireless-reconnect-count."
        WIRELESS_RECONNECT_COUNT=""
        return 1
    fi

    if ! ENABLE_TIME_UPDATE=$(parse_arg "--enable-time-update" "1" "$@"); then
        error "Failed to parse arg: --enable-time-update."
        ENABLE_TIME_UPDATE=""
        return 1
    fi

    if ! TIME_UPDATE_INTERVAL=$(parse_arg "--time-update-interval" "86400" "$@"); then
        error "Failed to parse arg: --time-update-interval."
        TIME_UPDATE_INTERVAL=""
        return 1
    fi

    if ! NTP_SERVER=$(parse_arg "--ntp-server" "pool.ntp.org" "$@"); then
        error "Failed to parse arg: --ntp-server."
        NTP_SERVER=""
        return 1
    fi

    if ! ENABLE_WEATHER=$(parse_arg "--enable-weather-update" "1" "$@"); then
        error "Failed to parse arg: --enable-weather-update."
        ENABLE_WEATHER=""
        return 1
    fi

    if ! WEATHER_UPDATE_INTERVAL=$(parse_arg "--weather-update-interval" "3600" "$@"); then
        error "Failed to parse arg: --weather-update-interval."
        WEATHER_UPDATE_INTERVAL=""
        return 1
    fi

    if ! WEATHER_UPDATE_TIMEOUT=$(parse_arg "--weather-update-timeout" "30" "$@"); then
        error "Failed to parse arg: --weather-update-timeout."
        WEATHER_UPDATE_TIMEOUT=""
        return 1
    fi

    if ! WEATHER_LOCATION=$(parse_arg "--weather-location" "" "$@"); then
        error "Failed to parse arg: --weather-location."
        WEATHER_LOCATION=""
        return 1
    fi
}

setup() {
    local screen_size

    if ! TRANSLATIONS=$(get_translations); then
        error "Failed to get translations."
        TRANSLATIONS=""
        return 1
    fi

    if ! WEATHER_LANGUAGE=$(get_wttr_language); then
        error "Failed to get WTTR language."
        WEATHER_LANGUAGE=""
        return 1
    fi
    debug "Weather language: $WEATHER_LANGUAGE"

    if ! screen_size=$(get_screen_size); then
        error "Failed to get screen size."
        screen_size=""
        return 1
    fi

    set -- $screen_size

    SCREEN_WIDTH="$1"
    SCREEN_HEIGHT="$2"
    debug "Screen size: $SCREEN_HEIGHT * $SCREEN_WIDTH"

    if ! RTC_WAKEALARM=$(get_rtc_wakealarm); then
        error "Failed to get RTC wakealarm."
        RTC_WAKEALARM=""
        return 1
    fi 
    debug "RTC wakealarm: $RTC_WAKEALARM"

    # Save prevent screensaver
    if ! PREVENT_SCREENSAVER=$(get_prevent_screensaver); then
        error "Failed to get prevent screensaver."
        PREVENT_SCREENSAVER=""
        return 1
    fi
    debug "Prevent screensaver: $PREVENT_SCREENSAVER"

    if ! set_prevent_screensaver "1"; then
        error "Failed to set prevent screensaver: 1"
        return 1
    fi

    # Save wireless enable
    if ! WIRELESS_ENABLE=$(get_wireless_enable); then
        error "Failed to get wireless enable"
        WIRELESS_ENABLE=""
        return 1
    fi
    debug "Wireless enable: $WIRELESS_ENABLE"

    TIME_UPDATE_AT=0

    WEATHER_UPDATE_AT=0
    WEATHER=""

    return 0
}

on_exit() {
    # Clear RTC wakealarm
    if [ -n "$RTC_WAKEALARM" ]; then
        if ! echo 0 > "$RTC_WAKEALARM"; then
            warning "Failed to clear RTC alarm."
        fi
    fi

    # Restore prevent screenersaver
    if [ -n "$PREVENT_SCREENSAVER" ]; then
        if ! set_prevent_screensaver "$PREVENT_SCREENSAVER"; then
            warning "Failed to set prevent screensaver: $PREVENT_SCREENSAVER."
        fi
    fi

    # Retore wireless enable
    if [ -n "$WIRELESS_ENABLE" ]; then
        if ! set_wireless_enable "$WIRELESS_ENABLE"; then
            warning "Failed to set wireless enable: $WIRELESS_ENABLE."
        fi
    fi
}

main () {
    if ! parse_args "$@"; then
        error "Failed to parse args."
        return 1
    fi

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