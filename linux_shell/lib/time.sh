#!/bin/bash
# 时间窗口模块

time_to_minutes() {
    local time_str="$1"
    local hour minute
    hour=$(echo "$time_str" | cut -d: -f1)
    minute=$(echo "$time_str" | cut -d: -f2)
    echo $((10#$hour * 60 + 10#$minute))
}

check_single_window() {
    local window="$1"
    local current_hour="$2"
    local current_minute="$3"

    local start_time end_time
    IFS='-' read -r start_time end_time <<< "$window"

    local start_minutes end_minutes current_minutes
    start_minutes=$(time_to_minutes "$start_time")
    end_minutes=$(time_to_minutes "$end_time")
    current_minutes=$((10#$current_hour * 60 + 10#$current_minute))

    if ((start_minutes<=end_minutes)); then
        ((current_minutes>=start_minutes)) && ((current_minutes<end_minutes))
    else
        ((current_minutes>=start_minutes)) || ((current_minutes<end_minutes))
    fi
}

is_in_time_window() {
    [ -z "$TIME_WINDOWS" ] && return 0

    local current_hour current_minute
    current_hour=$(date +%H)
    current_minute=$(date +%M)

    for window in $TIME_WINDOWS; do
        if check_single_window "$window" "$current_hour" "$current_minute"; then
            return 0
        fi
    done

    return 1
}

format_timestamp() {
    local timestamp="$1"
    date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S'
}
