#!/bin/bash
# 日志模块

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_msg="$timestamp - $level - $message"

    case "$level" in
        SUCCESS)
            echo "$log_msg" >> "$SUCCESS_LOG"
            [ "$VERBOSE" = true ] && echo "$log_msg"
            ;;
        ERROR)
            echo "$log_msg" >> "$ERROR_LOG"
            [ "$VERBOSE" = true ] && echo "$log_msg" >&2
            ;;
        INFO)
            [ "$VERBOSE" = true ] && echo "$log_msg"
            ;;
    esac
}

log_success() { log SUCCESS "$1"; }
log_error() { log ERROR "$1"; }
log_info() { log INFO "$1"; }
