#!/bin/bash
# 错误处理模块

classify_error() {
    local error_output="$1"
    local file_path="$2"

    if echo "$error_output" | grep -q "Permission denied"; then
        echo "permission_error"
    elif echo "$error_output" | grep -q "No space left on device"; then
        echo "disk_space_error"
    elif echo "$error_output" | grep -q "Connection refused\|Connection timed out\|Network is unreachable"; then
        echo "network_error"
    elif echo "$error_output" | grep -q "No such file or directory"; then
        echo "file_not_found_error"
    elif echo "$error_output" | grep -q "Input/output error"; then
        echo "io_error"
    else
        echo "unknown_error"
    fi
}

update_error_stats() {
    local error_type="$1"
    local file_path="$2"

    if [ ! -f "$ERROR_STATS_FILE" ]; then
        echo '{"total_errors": 0, "errors_by_type": {}, "failed_files": []}' > "$ERROR_STATS_FILE"
    fi

    if command -v jq >/dev/null 2>&1; then
        jq --arg error_type "$error_type" \
           --arg file_path "$file_path" \
           --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
           '.total_errors += 1 |
            .errors_by_type[$error_type] = (.errors_by_type[$error_type] // 0) + 1 |
            .failed_files += [{"file": $file_path, "error_type": $error_type, "timestamp": $timestamp}] |
            .failed_files = .failed_files[-100:]' \
           "$ERROR_STATS_FILE" > "${ERROR_STATS_FILE}.tmp" && mv "${ERROR_STATS_FILE}.tmp" "$ERROR_STATS_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $error_type - $file_path" >> "${ERROR_STATS_FILE}.txt"
    fi
}

show_error_report() {
    if [ -f "$ERROR_STATS_FILE" ]; then
        log_success "=== 错误统计报告 ==="

        if command -v jq >/dev/null 2>&1; then
            local total_errors
            total_errors=$(jq '.total_errors' "$ERROR_STATS_FILE")
            log_success "总错误数: $total_errors"

            log_success "按错误类型分类:"
            jq -r '.errors_by_type | to_entries | .[] | "  \(.key): \(.value)"' "$ERROR_STATS_FILE" | while read -r line; do
                log_success "$line"
            done

            local recent_failures
            recent_failures=$(jq '.failed_files | length' "$ERROR_STATS_FILE")
            if ((recent_failures>0)); then
                log_success "最近失败的文件 (最多100个):"
                jq -r '.failed_files[-5:] | .[] | "  \(.timestamp) - \(.error_type) - \(.file)"' "$ERROR_STATS_FILE" | while read -r line; do
                    log_success "$line"
                done
                if ((recent_failures>5)); then
                    log_success "  ... 还有 $((recent_failures - 5)) 个失败记录"
                fi
            fi
        else
            if [ -f "${ERROR_STATS_FILE}.txt" ]; then
                local error_count
                error_count=$(wc -l < "${ERROR_STATS_FILE}.txt")
                log_success "总错误数: $error_count"
                log_success "最近5个错误:"
                tail -5 "${ERROR_STATS_FILE}.txt" | while read -r line; do
                    log_success "  $line"
                done
            fi
        fi
        log_success "=== 报告结束 ==="
    else
        log_success "暂无错误统计信息"
    fi
}
