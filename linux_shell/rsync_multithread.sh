#!/bin/bash

#==============================================================================
# rsync_multithread.sh - 多线程rsync同步守护进程
#==============================================================================
# 版本: v2.1.0
# 作者: sgnay
# 描述: 企业级多线程rsync同步工具，支持时间窗口控制、增量同步、智能重试
#==============================================================================

VERSION="2.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/time.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/error.sh"

# 默认配置
SOURCE_DIR="/home/sgnay/Downloads/android/"
DEST_DIR="/home/sgnay/Downloads/android_bak/"
TIME_WINDOWS="06:00-08:00 09:00-13:00 14:00-18:30 21:00-23:30"
RSYNC_THREADS=4
BANDWIDTH_LIMIT=""
LOG_DIR="./rsync_daemon"
ERROR_LOG="$LOG_DIR/error.log"
SUCCESS_LOG="$LOG_DIR/success.log"
FILE_LIST="$LOG_DIR/file_list.txt"
LOCK_FILE="$LOG_DIR/rsync_daemon.lock"
CHECK_INTERVAL=300
TASK_QUEUE="$LOG_DIR/task_queue"
FLAG="$LOG_DIR/flag"
RSYNC_PID_FILE="$LOG_DIR/rsync_pids.pid"
MIN_FREE_SPACE_MB=4096
MAX_RETRY_COUNT=3
BASE_RETRY_DELAY=10
MAX_RETRY_DELAY=300
ERROR_STATS_FILE="$LOG_DIR/error_stats.json"
LAST_SYNC_FILE="$LOG_DIR/last_sync_time"
VERBOSE=false
DRY_RUN=false
CONFIG_FILE="./rsync_daemon.conf"

# 停止守护进程
stop_daemon() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if is_process_running "$lock_pid"; then
            echo "停止守护进程 (PID: $lock_pid)..."
            kill -TERM "$lock_pid"
            sleep 5
            if is_process_running "$lock_pid"; then
                echo "强制停止守护进程..."
                kill -KILL "$lock_pid"
            fi
            echo "守护进程已停止"
            cleanup
        else
            echo "没有运行中的守护进程"
        fi
    else
        echo "锁文件不存在，没有运行中的守护进程"
    fi
}

# 清理临时文件
cleanup_temp_files() {
    rm -f "$FILE_LIST"
    rm -f "$TASK_QUEUE"/*
    rm -f "$RSYNC_PID_FILE.lock"
    rm -f "$TASK_QUEUE/synced_size_lock"
}

# 检查flag
check_flag() {
    local flag
    flag=$(cat "$FLAG" 2>/dev/null)
    if [ "$flag" = quit ]; then
        log_success "收到退出信号，退出子线程"
        return 1
    elif [ "$flag" = full ]; then
        log_error "目标空间不足，退出子线程"
        return 1
    elif [ "$flag" = pause ]; then
        log_success "收到暂停信号，线程暂停 $CHECK_INTERVAL 秒后继续"
        sleep "$CHECK_INTERVAL"
    fi
    return 0
}

# 初始化任务队列
init_task_queue() {
    rm -f "$TASK_QUEUE"/*
    local total_tasks
    total_tasks=$(wc -l "$FILE_LIST" | awk '{print $1}')
    echo "$total_tasks" > "$TASK_QUEUE/total_tasks"
    echo 0 > "$TASK_QUEUE/completed_tasks"
    log_success "任务队列初始化完成，共 $total_tasks 个任务"
}

# 获取下一个任务
get_next_task() {
    (
        flock 200
        local completed total
        completed=$(cat "$TASK_QUEUE/completed_tasks" 2>/dev/null || echo 0)
        total=$(cat "$TASK_QUEUE/total_tasks" 2>/dev/null || echo 0)

        if ((completed<total)); then
            ((completed++))
            echo $completed > "$TASK_QUEUE/completed_tasks"
            awk "NR==$completed" "$FILE_LIST"
        else
            echo ""
        fi
    ) 200>"$TASK_QUEUE/lock"
}

# 获取任务进度
get_task_progress() {
    local total completed
    total=$(cat "$TASK_QUEUE/total_tasks" 2>/dev/null || echo 0)
    completed=$(cat "$TASK_QUEUE/completed_tasks" 2>/dev/null || echo 0)

    if ((total>0)); then
        echo "$completed/$total"
    else
        echo "0/0"
    fi
}

# 更新最后同步时间
update_last_sync_time() {
    local sync_time
    sync_time=$(date +%s)
    echo "$sync_time" > "$LAST_SYNC_FILE"
    log_success "更新上次同步时间: $(format_timestamp "$sync_time")"
}

# 生成文件列表
generate_file_list() {
    log_success "开始生成文件列表..."
    : > "$FILE_LIST"

    local last_sync_timestamp=0
    if [ -f "$LAST_SYNC_FILE" ]; then
        last_sync_timestamp=$(cat "$LAST_SYNC_FILE" 2>/dev/null || echo 0)
        log_success "读取最后同步时间: $(format_timestamp "$last_sync_timestamp")"
    else
        log_success "未找到同步时间戳，执行全量同步"
    fi

    local file_count=0
    local skipped_count=0

    if ((last_sync_timestamp>0)); then
        while IFS= read -r -d '' file_path; do
            local file_mtime
            file_mtime=$(stat -c %Y "$file_path" 2>/dev/null || echo 0)

            if ((file_mtime>last_sync_timestamp)); then
                echo "$file_path" >> "$FILE_LIST"
                ((file_count++))
            else
                ((skipped_count++))
            fi
        done < <(find "$SOURCE_DIR" -type f -print0 2>/dev/null)

        log_success "增量同步文件列表生成完成，新增/修改 $file_count 个文件，跳过 $skipped_count 个未修改文件"
    else
        if find "$SOURCE_DIR" -type f > "$FILE_LIST" 2>/dev/null; then
            file_count=$(wc -l < "$FILE_LIST")
            log_success "全量同步文件列表生成完成，共 $file_count 个文件"
        else
            log_error "生成文件列表失败"
            return 1
        fi
    fi

    if [ "$file_count" -eq 0 ]; then
        log_success "没有文件需要同步"
        return 2
    fi

    return 0
}

# 多线程rsync同步
multi_thread_rsync() {
    local source_dir="$1"
    local dest_dir="$2"
    local thread_count="$3"

    generate_file_list
    local generate_result=$?

    if ((generate_result==1)); then
        return 1
    elif ((generate_result==2)); then
        return 2
    fi

    init_task_queue

    local total_files
    total_files=$(cat "$TASK_QUEUE/total_tasks")

    log_success "开始同步，总共 $total_files 个文件，使用 $thread_count 个线程"

    local df_output
    df_output=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$df_output" ] || ! [[ "$df_output" =~ ^[0-9]+$ ]]; then
        log_error "无法获取目标磁盘空间信息: $DEST_DIR"
        return 1
    fi
    local free_space=0
    ((free_space+=df_output))
    echo 0 > "$TASK_QUEUE/total_synced_size"

    local pids=()
    ((rsync_start_time=$(date +%s)))

    for ((i=1; i<=thread_count; i++)); do
        (
            local thread_id=$i
            log_success "线程 $thread_id 启动"

            _cleanup_thread() {
                log_success "线程 $thread_id 收到终止信号，正在退出..."
                remove_pid_from_file
                exit 0
            }
            trap '_cleanup_thread' SIGTERM SIGINT

            while true; do
                check_flag || _cleanup_thread
                until is_in_time_window; do
                    log_success "不在时间窗口内，等待下一次检查"
                    sleep "$CHECK_INTERVAL"
                done

                local file_path
                file_path=$(get_next_task)
                if [ -z "$file_path" ]; then
                    log_success "线程 $thread_id 完成所有任务"
                    break 2
                fi

                if [ -f "$file_path" ]; then
                    local relative_path="${file_path#"$source_dir"}"
                    local dest_path="$dest_dir/$relative_path"
                    local dest_dir_path
                    dest_dir_path="$(dirname "$dest_path")"

                    local file_size current_total_synced
                    file_size=$(stat -c %s "$file_path" 2>/dev/null)
                    if [ -z "$file_size" ] || ! [[ "$file_size" =~ ^[0-9]+$ ]]; then
                        log_error "无法获取文件大小: $file_path"
                        continue
                    fi

                    current_total_synced=$(
                        (
                            flock -s 201
                            cat "$TASK_QUEUE/total_synced_size" 2>/dev/null || echo 0
                        ) 201>"$TASK_QUEUE/synced_size_lock"
                    )

                    if (((free_space - MIN_FREE_SPACE_MB*1024*1024 - current_total_synced - file_size)<0)); then
                        log_error "目标空间不足，退出！"
                        echo "full" > "$FLAG"
                        break
                    fi

                    mkdir -p "$dest_dir_path"

                    local sync_result
                    sync_result=$(sync_with_retry "$file_path" "$dest_path" "$relative_path")

                    if [ "$sync_result" = "success" ]; then
                        local rsync_thread_end_time rsync_duration average_rate new_total_synced

                        (
                            flock -x 201
                            local synced
                            synced=$(cat "$TASK_QUEUE/total_synced_size" 2>/dev/null || echo 0)
                            echo $((synced + file_size)) > "$TASK_QUEUE/total_synced_size"
                        ) 201>"$TASK_QUEUE/synced_size_lock"
                        new_total_synced=$(cat "$TASK_QUEUE/total_synced_size")

                        rsync_thread_end_time=$(date +%s)
                        rsync_duration=$((rsync_thread_end_time-rsync_start_time+1))
                        local available_space_now
                        available_space_now=$((free_space - MIN_FREE_SPACE_MB*1024*1024 - new_total_synced))

                        average_rate=$((new_total_synced/1048576/rsync_duration))
                        log_success "同步成功: $relative_path (进度: $(get_task_progress)), 文件大小: $(human_readable_size "$file_size"), 同步耗时: $rsync_duration 秒, 平均速度: $average_rate MB/s， 目标剩余空间 $(human_readable_size "$available_space_now")"
                    else
                        local error_msg
                        error_msg=$(echo "$sync_result" | cut -d':' -f2-)
                        log_error "同步失败: $relative_path - $error_msg"
                    fi
                else
                    log_error "文件不存在: $file_path"
                fi
            done
            remove_pid_from_file
        ) &
        sleep 0.1
        pids+=($!)
    done

    printf "%s\n" "${pids[@]}" > "$RSYNC_PID_FILE"

    local completed=0
    local total=${#pids[@]}

    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((completed++))
        else
            log_error "线程 $pid 异常退出"
        fi
    done

    log_success "同步任务完成: $completed/$total 个线程成功完成"

    rm -f "$RSYNC_PID_FILE"
    cleanup_temp_files

    return 0
}

# 检查rsync进程
is_rsync_running() {
    local child_rsync_pids
    child_rsync_pids=$(pgrep -P $$ -x rsync 2>/dev/null)
    [ -n "$child_rsync_pids" ]
}

# 等待rsync完成
wait_for_rsync_completion() {
    local timeout=3600
    local waited=0

    while is_rsync_running && ((waited<timeout)); do
        log_success "等待rsync进程完成... (已等待 ${waited}秒)"
        sleep 10
        ((waited+=10))
    done

    if is_rsync_running; then
        log_error "rsync进程超时，强制终止"
        pkill -P $$ -x rsync
        sleep 5
    fi
}

# 主循环
main_loop() {
    log_success "rsync守护进程启动"
    log_info "配置信息已加载，开始主循环"

    while true; do
        if is_in_time_window; then
            log_success "在时间窗口内，开始同步任务"

            check_flag || cleanup
            if multi_thread_rsync "$SOURCE_DIR" "$DEST_DIR" "$RSYNC_THREADS"; then
                update_last_sync_time
                log_success "同步完成，等待下一次检查"
            else
                local sync_result=$?
                if [ $sync_result -eq 2 ]; then
                    update_last_sync_time
                    log_success "没有文件需要同步，等待下一次检查"
                else
                    log_error "同步过程中出现错误，等待下一次检查"
                fi
            fi

            check_flag || cleanup
            sleep "$CHECK_INTERVAL"
        else
            log_success "不在时间窗口内"
            if is_rsync_running; then
                log_success "有rsync进程正在运行，等待完成..."
                wait_for_rsync_completion
                log_success "所有rsync进程已完成"
            fi
            log_success "等待进入时间窗口..."
            sleep "$CHECK_INTERVAL"
        fi
    done
}

# 清理函数
cleanup() {
    log_success "脚本被终止，执行清理操作"

    echo "quit" > "$FLAG"

    if [ -f "$RSYNC_PID_FILE" ]; then
        log_success "正在停止工作线程..."
        while read -r worker_pid; do
            if is_process_running "$worker_pid"; then
                kill -TERM "$worker_pid" 2>/dev/null
                log_success "已向工作线程 $worker_pid 发送终止信号"
            fi
        done < "$RSYNC_PID_FILE"

        local waited=0
        while [ -f "$RSYNC_PID_FILE" ] && ((waited<30)); do
            sleep 1
            ((waited++))
        done

        if [ -f "$RSYNC_PID_FILE" ]; then
            log_success "部分工作线程未响应，强制终止..."
            while read -r worker_pid; do
                if is_process_running "$worker_pid"; then
                    kill -KILL "$worker_pid" 2>/dev/null
                fi
            done < "$RSYNC_PID_FILE"
        fi
    fi

    show_error_report
    cleanup_temp_files
    rm -f "$RSYNC_PID_FILE"
    remove_lock

    exit 0
}

trap cleanup SIGINT SIGTERM

# 主程序
main() {
    export -f check_flag
    export -f get_next_task
    export -f is_in_time_window
    export -f log_success
    export -f log_error
    export -f log_info
    export -f sync_with_retry
    export -f classify_error
    export -f update_error_stats
    export -f get_task_progress
    export -f human_readable_size
    export -f remove_pid_from_file
    export -f is_process_running
    export -f format_timestamp

    load_config

    mkdir -p "$LOG_DIR" "$TASK_QUEUE"

    parse_arguments "$@"
    : > "$FLAG"
    if [ "$DRY_RUN" = true ]; then
        show_config
        exit 0
    fi

    [ "$VERBOSE" = true ] && show_config

    if [ ! -d "$SOURCE_DIR" ]; then
        echo "错误: 源目录 $SOURCE_DIR 不存在" | tee -a "$ERROR_LOG"
        exit 1
    fi

    if [ ! -d "$DEST_DIR" ]; then
        echo "警告: 目标目录 $DEST_DIR 不存在，尝试创建" | tee -a "$ERROR_LOG"
        mkdir -p "$DEST_DIR" || {
            echo "错误: 无法创建目标目录 $DEST_DIR" | tee -a "$ERROR_LOG"
            exit 1
        }
    fi

    if ! command -v flock >/dev/null 2>&1; then
        echo "错误: flock 命令不可用，请安装 util-linux 包" | tee -a "$ERROR_LOG"
        exit 1
    fi

    if ! command -v rsync >/dev/null 2>&1; then
        echo "错误: rsync 命令不可用，请安装 rsync 包" | tee -a "$ERROR_LOG"
        exit 1
    fi

    if ! create_lock; then
        echo "错误: 无法创建锁文件，可能已有实例在运行" | tee -a "$ERROR_LOG"
        echo "使用 --stop 参数可以停止正在运行的守护进程"
        exit 1
    fi

    main_loop
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
