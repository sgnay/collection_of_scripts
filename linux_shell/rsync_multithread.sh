#!/bin/bash

# 配置参数
SOURCE_DIR="/home/sgnay/Downloads/android/"                    # 源目录
DEST_DIR="/home/sgnay/Downloads/android_bak/"                # 目标目录
DAILY_WINDOW_START="06:00"           # 每天开始时间 (24小时制)
DAILY_WINDOW_END="22:00"             # 每天结束时间 (24小时制)
RSYNC_THREADS=4                      # 并发线程数
LOG_DIR="./rsync_daemon"      # 日志目录
ERROR_LOG="$LOG_DIR/error.log"       # 错误日志
SUCCESS_LOG="$LOG_DIR/success.log"   # 成功日志
FILE_LIST="$LOG_DIR/file_list.txt"   # 文件列表临时文件
LOCK_FILE="$LOG_DIR/rsync_daemon.lock" # 锁文件
CHECK_INTERVAL=300                   # 检查间隔(秒)
TASK_QUEUE="$LOG_DIR/task_queue"     # 任务队列目录

# 创建日志目录和任务队列
mkdir -p "$LOG_DIR" "$TASK_QUEUE"

# 记录日志函数
log_success() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS - $1" >> "$SUCCESS_LOG"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $1" >> "$ERROR_LOG"
}

# 锁文件函数
create_lock() {
    # 检查锁文件是否存在
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # 检查进程是否还在运行
        if ps -p "$lock_pid" > /dev/null 2>&1; then
            log_error "锁文件已存在，进程 $lock_pid 正在运行，脚本退出"
            return 1
        else
            log_success "发现僵尸锁文件，进程 $lock_pid 已不存在，清理并继续"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 创建锁文件
    if echo $$ > "$LOCK_FILE"; then
        log_success "锁文件创建成功: $LOCK_FILE (PID: $$)"
        return 0
    else
        log_error "锁文件创建失败: $LOCK_FILE"
        return 1
    fi
}

# 删除锁文件
remove_lock() {
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log_success "锁文件已删除: $LOCK_FILE"
    fi
}

# 检查锁文件
check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if ps -p "$lock_pid" > /dev/null 2>&1; then
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

# 检查是否在时间窗口内
is_in_time_window() {
    local current_hour current_minute start_hour start_minute end_hour end_minute
    current_hour=$(date +%H)
    current_minute=$(date +%M)
    
    start_hour=$(echo $DAILY_WINDOW_START | cut -d: -f1)
    start_minute=$(echo $DAILY_WINDOW_START | cut -d: -f2)
    end_hour=$(echo $DAILY_WINDOW_END | cut -d: -f1)
    end_minute=$(echo $DAILY_WINDOW_END | cut -d: -f2)
    
    # 如果开始时间小于结束时间（不跨天）
    if [ "$start_hour" -lt "$end_hour" ] || ([ "$start_hour" -eq "$end_hour" ] && [ "$start_minute" -lt "$end_minute" ]); then
        if [ "$current_hour" -gt "$start_hour" ] || ([ "$current_hour" -eq "$start_hour" ] && [ "$current_minute" -ge "$start_minute" ]); then
            if [ "$current_hour" -lt "$end_hour" ] || ([ "$current_hour" -eq "$end_hour" ] && [ "$current_minute" -lt "$end_minute" ]); then
                return 0
            fi
        fi
        return 1
    else
        # 跨天情况
        if [ "$current_hour" -gt "$start_hour" ] || ([ "$current_hour" -eq "$start_hour" ] && [ "$current_minute" -ge "$start_minute" ]); then
            return 0
        elif [ "$current_hour" -lt "$end_hour" ] || ([ "$current_hour" -eq "$end_hour" ] && [ "$current_minute" -lt "$end_minute" ]); then
            return 0
        else
            return 1
        fi
    fi
}

# 生成文件列表
generate_file_list() {
    log_success "开始生成文件列表..."
    # 清空旧文件列表
    : > "$FILE_LIST"
    
    # 使用find逐行写入文件，避免内存占用
    if find "$SOURCE_DIR" -type f > "$FILE_LIST" 2>/dev/null; then
        local file_count
        file_count=$(wc -l < "$FILE_LIST")
        log_success "文件列表生成完成，共 $file_count 个文件"
        return 0
    else
        log_error "生成文件列表失败"
        return 1
    fi
}

# 初始化任务队列
init_task_queue() {
    # 清空任务队列目录
    rm -f "$TASK_QUEUE"/*
    
    # 记录任务总数
    local total_tasks
    total_tasks=$(wc -l "$FILE_LIST" | awk '{print $1}')
    echo "$total_tasks" > "$TASK_QUEUE/total_tasks"
    
    # 初始化记录已完成任务数
    echo 0 > "$TASK_QUEUE/completed_tasks"
    
    log_success "任务队列初始化完成，共 $total_tasks 个任务"
}

# 使用原子操作获取下一个任务
get_next_task() {
    # 使用文件锁保护共享资源
    (
        flock -x 200
        local completed total
        completed=$(cat "$TASK_QUEUE/completed_tasks" 2>/dev/null || echo 0)
        total=$(cat "$TASK_QUEUE/total_tasks" 2>/dev/null || echo 0)
        
        if [ "$completed" -lt "$total" ]; then
            let completed++
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
    
    if [ "$total" -gt 0 ]; then
        echo "$completed/$total"
    else
        echo "0/0"
    fi
}

# 多线程rsync同步函数
multi_thread_rsync() {
    local source_dir="$1"
    local dest_dir="$2"
    local thread_count="$3"
    
    # 生成文件列表
    if ! generate_file_list; then
        return 1
    fi
    
    # 初始化任务队列
    init_task_queue
    
    local total_files
    total_files=$(cat "$TASK_QUEUE/total_tasks")
    
    log_success "开始同步，总共 $total_files 个文件，使用 $thread_count 个线程"
    
    # 创建进程数组
    local pids=()
    
    for ((i=1; i<=thread_count; i++)); do
        (
            local thread_id=$i
            log_success "线程 $thread_id 启动"
            
            while true; do
                # 获取下一个任务
                local file_path
                file_path=$(get_next_task)
                if [ -z "$file_path" ]; then
                    # 没有更多任务
                    log_success "线程 $thread_id 完成所有任务"
                    break
                fi
                
                if [ -f "$file_path" ]; then
                    # 从 file_path 左边删除 source_dir
                    local relative_path="${file_path#"$source_dir"}"
                    local dest_path="$dest_dir/$relative_path"
                    local dest_dir_path
                    dest_dir_path="$(dirname "$dest_path")"
                    
                    # 创建目标目录
                    mkdir -p "$dest_dir_path"
                    
                    # 使用rsync同步文件
                    rsync_start_time=$(date +%s)
                    if rsync -avzcP "$file_path" "$dest_path" 2>>"$ERROR_LOG"; then
                        rsync_end_time=$(date +%s)
                        rsync_duration=$(echo | awk "{print $rsync_end_time-$rsync_start_time+0.01}") # 防止出现0
                        file_size=$(stat -c %s "$file_path")
                        file_size_kb=$(echo | awk "{print $file_size/1024}")
                        average_rate=$(echo | awk "{print $file_size_kb/$rsync_duration}")
                        log_success "同步成功: $relative_path (进度: $(get_task_progress)), 文件大小: $file_size_kb KB, 同步耗时: $rsync_duration 秒, 平均速度: $average_rate KB/s"
                    else
                        log_error "同步失败: $relative_path"
                    fi
                else
                    log_error "文件不存在: $file_path"
                fi
            done
        ) &
        sleep 1
        pids+=($!)
    done
    
    # 等待所有进程完成
    local completed=0
    local total=${#pids[@]}
    
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            completed=$((completed + 1))
        fi
    done
    
    log_success "同步任务完成: $completed/$total 个线程成功完成"
    
    # 清理临时文件
    rm -f "$FILE_LIST"
    rm -f "$TASK_QUEUE"/*
    
    return 0
}

# 检查是否有rsync进程在运行
is_rsync_running() {
    pgrep -x rsync >/dev/null
}

# 等待rsync进程完成
wait_for_rsync_completion() {
    local timeout=3600  # 最大等待1小时
    local waited=0
    
    while is_rsync_running && [ $waited -lt $timeout ]; do
        log_success "等待rsync进程完成... (已等待 ${waited}秒)"
        sleep 10
        waited=$((waited + 10))
    done
    
    if is_rsync_running; then
        log_error "rsync进程超时，强制终止"
        pkill -x rsync
        sleep 5
    fi
}

# 主循环
main_loop() {
    while true; do
        if is_in_time_window; then
            log_success "在时间窗口内，开始同步任务"
            multi_thread_rsync "$SOURCE_DIR" "$DEST_DIR" "$RSYNC_THREADS"
            log_success "同步完成，等待下一次检查"
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
    # 清理临时文件
    rm -f "$FILE_LIST"
    rm -f "$TASK_QUEUE"/*
    # 删除锁文件
    remove_lock
    # 等待可能正在运行的rsync进程
    wait_for_rsync_completion
    exit 0
}

# 信号处理
trap cleanup SIGINT SIGTERM

# 启动前检查
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

# 检查flock命令是否可用
if ! command -v flock >/dev/null 2>&1; then
    echo "错误: flock 命令不可用，请安装 util-linux 包" | tee -a "$ERROR_LOG"
    exit 1
fi

# 锁文件检查
if ! create_lock; then
    echo "错误: 无法创建锁文件，可能已有实例在运行" | tee -a "$ERROR_LOG"
    exit 1
fi

# 启动脚本
log_success "rsync守护进程启动"
log_success "源目录: $SOURCE_DIR"
log_success "目标目录: $DEST_DIR"
log_success "时间窗口: $DAILY_WINDOW_START - $DAILY_WINDOW_END"
log_success "并发线程数: $RSYNC_THREADS"
log_success "检查间隔: ${CHECK_INTERVAL}秒"

main_loop
