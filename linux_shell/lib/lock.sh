#!/bin/bash
# 锁机制模块

is_process_running() {
    local pid="$1"
    ps -p "$pid" > /dev/null 2>&1
}

create_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if is_process_running "$lock_pid"; then
            log_error "锁文件已存在，进程 $lock_pid 正在运行，脚本退出"
            return 1
        else
            log_success "发现僵尸锁文件，进程 $lock_pid 已不存在，清理并继续"
            rm -f "$LOCK_FILE"
        fi
    fi

    if echo $$ > "$LOCK_FILE"; then
        log_success "锁文件创建成功: $LOCK_FILE (PID: $$)"
        return 0
    else
        log_error "锁文件创建失败: $LOCK_FILE"
        return 1
    fi
}

remove_lock() {
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log_success "锁文件已删除: $LOCK_FILE"
    fi
}

check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if is_process_running "$lock_pid"; then
            log_error "另一个实例正在运行 (PID: $lock_pid)，当前脚本退出"
            return 1
        else
            log_success "发现僵尸锁文件，清理后继续"
            rm -f "$LOCK_FILE"
            return 0
        fi
    fi
    return 0
}

remove_pid_from_file() {
    (
        flock -x 202
        if [ -f "$RSYNC_PID_FILE" ]; then
            grep -v "^$$\$" "$RSYNC_PID_FILE" > "${RSYNC_PID_FILE}.tmp" 2>/dev/null || true
            mv "${RSYNC_PID_FILE}.tmp" "$RSYNC_PID_FILE" 2>/dev/null || true
            if [ ! -s "$RSYNC_PID_FILE" ]; then
                rm -f "$RSYNC_PID_FILE"
            fi
        fi
    ) 202>"$RSYNC_PID_FILE.lock"
}
