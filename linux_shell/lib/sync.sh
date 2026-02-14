#!/bin/bash
# rsync同步模块

human_readable_size() {
    local bytes=$1
    if [[ -z "$bytes" || "$bytes" -lt 0 ]]; then
        echo "0 B"
        return
    fi

    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local idx=0
    local value=$bytes

    while ((value >= 1024 && idx < ${#units[@]} - 1)); do
        ((value /= 1024))
        ((idx++))
    done

    if [ $idx -eq 0 ]; then
        printf "%d %s\n" "$value" "${units[$idx]}"
    else
        printf "%.2f %s\n" "$value" "${units[$idx]}"
    fi
}

sync_with_retry() {
    local file_path="$1"
    local dest_path="$2"
    local relative_path="$3"

    local retry_count=0
    local success=false
    local last_error=""

    local rsync_args="-avzcP"
    if [ -n "$BANDWIDTH_LIMIT" ]; then
        rsync_args="--bwlimit=$BANDWIDTH_LIMIT $rsync_args"
        log_info "使用带宽限制: $BANDWIDTH_LIMIT"
    fi

    while ((retry_count<MAX_RETRY_COUNT)) && [ "$success" = false ]; do
        if ((retry_count>0)); then
            local backoff_delay=$((BASE_RETRY_DELAY * (1 << (retry_count - 1))))
            if ((backoff_delay>MAX_RETRY_DELAY)); then
                backoff_delay=$MAX_RETRY_DELAY
            fi
            log_success "重试 $retry_count/$MAX_RETRY_COUNT: $relative_path (等待 ${backoff_delay}秒)"
            sleep "$backoff_delay"
        fi

        local error_output
        error_output=$(rsync $rsync_args "$file_path" "$dest_path" 2>&1)
        local rsync_exit_code=$?

        if [ $rsync_exit_code -eq 0 ]; then
            success=true
        else
            last_error="$error_output"
            retry_count=$((retry_count + 1))

            local error_type
            error_type=$(classify_error "$error_output" "$file_path")
            update_error_stats "$error_type" "$file_path"

            case "$error_type" in
                "disk_space_error")
                    log_error "磁盘空间错误，停止重试: $relative_path"
                    echo "full" > "$FLAG"
                    return 1
                    ;;
                "permission_error")
                    if ((retry_count>=2)); then
                        log_error "权限错误，跳过文件: $relative_path"
                        return 1
                    fi
                    ;;
                "network_error")
                    log_error "网络错误 ($error_type): $relative_path (尝试 $retry_count/$MAX_RETRY_COUNT)"
                    ;;
                *)
                    log_error "同步失败 ($error_type): $relative_path (尝试 $retry_count/$MAX_RETRY_COUNT)"
                    ;;
            esac
        fi
    done

    if [ "$success" = true ]; then
        echo "success"
    else
        echo "failed:$last_error"
    fi
}
