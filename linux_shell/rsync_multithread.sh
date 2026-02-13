#!/bin/bash

#==============================================================================
# rsync_multithread.sh - 多线程rsync同步守护进程
#==============================================================================
# 
# 版本: v2.0.0
# 作者: [自动生成]
# 描述: 企业级多线程rsync同步工具，支持时间窗口控制、增量同步、智能重试
# 
# 主要特性:
#   - 多线程并发同步，提高传输效率
#   - 基于文件修改时间的智能增量同步
#   - 灵活的时间窗口控制，避免影响业务时间
#   - 指数退避重试机制，根据错误类型采用不同策略
#   - 带宽限制支持，避免网络拥堵
#   - 完整的错误统计和分类
#   - 进程锁机制，防止多实例冲突
#   - 优雅的信号处理和资源清理
#   - 详细的日志记录和监控
#   - 配置文件支持，便于部署管理
#
# 使用方法:
#   ./rsync_multithread.sh [选项]
#   ./rsync_multithread.sh --help    # 查看详细帮助
#   ./rsync_multithread.sh --stop    # 停止运行中的守护进程
#
# 依赖项:
#   - bash (>= 4.0)
#   - rsync
#   - coreutils (find, stat, awk, etc.)
#   - util-linux (flock)
#   - jq (可选，用于JSON统计)
#
#==============================================================================

# 脚本版本
VERSION="2.0.0"

# 显示帮助信息
show_help() {
    cat << EOF
rsync_multithread.sh v$VERSION - 多线程rsync同步守护进程

用法: $0 [选项]

选项:
    -c, --config FILE     指定配置文件路径 (默认: ./rsync_daemon.conf)
    -s, --source DIR      源目录路径
    -d, --dest DIR        目标目录路径
    -t, --threads NUM     并发线程数 (默认: 4)
    -w, --windows TIMES   时间窗口，格式: "06:00-08:00 12:00-14:00"
    -b, --bandwidth LIMIT 带宽限制，如: "10M" (10MB/s), "100K" (100KB/s)
    -i, --interval SEC    检查间隔秒数 (默认: 300)
    -r, --retry NUM       最大重试次数 (默认: 3)
    -m, --min-space MB    最小保留空间MB (默认: 4096)
    -v, --verbose         详细输出模式
    -h, --help            显示此帮助信息
    --dry-run            仅显示配置，不执行同步
    --stop               停止正在运行的守护进程

配置文件格式:
    SOURCE_DIR="/path/to/source"
    DEST_DIR="/path/to/dest"
    TIME_WINDOWS="06:00-08:00 12:00-14:00"
    RSYNC_THREADS=4
    BANDWIDTH_LIMIT="10M"
    # ... 其他配置项

示例:
    $0 -s /home/user/data -d /backup/data -t 8 -b 5M
    $0 --config /etc/rsync_daemon.conf
    $0 --stop

EOF
}

# 默认配置参数
SOURCE_DIR="/home/sgnay/Downloads/android/"
DEST_DIR="/home/sgnay/Downloads/android_bak/"
TIME_WINDOWS="06:00-08:00 12:00-13:00 14:00-18:20 22:00-23:30"
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
MIN_FREE_SPACE_MB=4096
MAX_RETRY_COUNT=3
BASE_RETRY_DELAY=10
ERROR_STATS_FILE="$LOG_DIR/error_stats.json"
LAST_SYNC_FILE="$LOG_DIR/last_sync_time"
VERBOSE=false
DRY_RUN=false
CONFIG_FILE="./rsync_daemon.conf"

# 加载配置文件
# 功能：从外部配置文件中读取配置参数，覆盖默认值
# 安全特性：
#   - 跳过注释行（以#开头）
#   - 跳过空行
#   - 自动移除配置值前后的引号
#   - 只允许预定义的配置项，防止配置注入
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_success "加载配置文件: $CONFIG_FILE"
        # 逐行读取配置文件，安全地解析配置项
        while IFS='=' read -r key value; do
            # 跳过注释行（以#开头或包含#的行）
            [[ $key =~ ^[[:space:]]*# ]] && continue
            # 跳过空行
            [[ -z $key ]] && continue
            
            # 移除值前后的单引号或双引号，支持带空格的路径
            value=$(echo "$value" | sed 's/^["'\'']//' | sed 's/["'\'']$//')
            
            # 使用case语句安全地设置配置项，只允许预定义的配置项
            case "$key" in
                SOURCE_DIR) SOURCE_DIR="$value" ;;
                DEST_DIR) DEST_DIR="$value" ;;
                TIME_WINDOWS) TIME_WINDOWS="$value" ;;
                RSYNC_THREADS) RSYNC_THREADS="$value" ;;
                BANDWIDTH_LIMIT) BANDWIDTH_LIMIT="$value" ;;
                LOG_DIR) LOG_DIR="$value" ;;
                CHECK_INTERVAL) CHECK_INTERVAL="$value" ;;
                MIN_FREE_SPACE_MB) MIN_FREE_SPACE_MB="$value" ;;
                MAX_RETRY_COUNT) MAX_RETRY_COUNT="$value" ;;
                BASE_RETRY_DELAY) BASE_RETRY_DELAY="$value" ;;
            esac
        done < "$CONFIG_FILE"
    else
        log_success "配置文件不存在，使用默认配置: $CONFIG_FILE"
    fi
}

# 解析命令行参数
# 功能：解析用户输入的命令行参数，覆盖默认配置和配置文件设置
# 支持短选项（-s）和长选项（--source）两种格式
# 参数验证：对于需要参数值的选项，检查参数是否存在
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)          # 配置文件路径
                CONFIG_FILE="$2"
                shift 2
                ;;
            -s|--source)          # 源目录路径
                SOURCE_DIR="$2"
                shift 2
                ;;
            -d|--dest)            # 目标目录路径
                DEST_DIR="$2"
                shift 2
                ;;
            -t|--threads)         # 并发线程数
                RSYNC_THREADS="$2"
                shift 2
                ;;
            -w|--windows)         # 时间窗口配置
                TIME_WINDOWS="$2"
                shift 2
                ;;
            -b|--bandwidth)       # 带宽限制
                BANDWIDTH_LIMIT="$2"
                shift 2
                ;;
            -i|--interval)        # 检查间隔
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -r|--retry)           # 最大重试次数
                MAX_RETRY_COUNT="$2"
                shift 2
                ;;
            -m|--min-space)       # 最小保留空间
                MIN_FREE_SPACE_MB="$2"
                shift 2
                ;;
            -v|--verbose)         # 详细输出模式（无参数选项）
                VERBOSE=true
                shift
                ;;
            -h|--help)            # 显示帮助信息
                show_help
                exit 0
                ;;
            --dry-run)            # 干运行模式，仅显示配置
                DRY_RUN=true
                shift
                ;;
            --stop)               # 停止正在运行的守护进程
                stop_daemon
                exit 0
                ;;
            *)                    # 未知选项处理
                echo "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 停止守护进程
# 功能：优雅地停止正在运行的守护进程
# 实现步骤：
#   1. 检查锁文件是否存在
#   2. 读取锁文件中的进程ID
#   3. 验证进程是否仍在运行
#   4. 发送TERM信号进行优雅停止
#   5. 等待5秒后检查进程是否已停止
#   6. 如果仍在运行，发送KILL信号强制停止
stop_daemon() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # 验证进程是否仍在运行
        if ps -p "$lock_pid" > /dev/null 2>&1; then
            echo "停止守护进程 (PID: $lock_pid)..."
            # 发送TERM信号，允许进程优雅退出
            kill -TERM "$lock_pid"
            # 等待进程清理资源并退出
            sleep 5
            # 检查进程是否已停止
            if ps -p "$lock_pid" > /dev/null 2>&1; then
                echo "强制停止守护进程..."
                # 如果优雅停止失败，强制杀死进程
                kill -KILL "$lock_pid"
            fi
            cleanup
            echo "守护进程已停止"
        else
            echo "没有运行中的守护进程"
        fi
    else
        echo "锁文件不存在，没有运行中的守护进程"
    fi
}

# 创建日志目录和任务队列
mkdir -p "$LOG_DIR" "$TASK_QUEUE"

# 记录成功日志
# 功能：记录成功操作的日志信息
# 输出：同时写入日志文件和（如果启用详细模式）控制台
# 格式：时间戳 - SUCCESS - 消息内容
log_success() {
    local message
    message="$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS - $1"
    # 写入成功日志文件
    echo "$message" >> "$SUCCESS_LOG"
    # 如果启用详细模式，同时输出到控制台
    [ "$VERBOSE" = true ] && echo "$message"
}

# 记录错误日志
# 功能：记录错误信息的日志
# 输出：同时写入日志文件和（如果启用详细模式）标准错误
# 格式：时间戳 - ERROR - 消息内容
log_error() {
    local message
    message="$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $1"
    # 写入错误日志文件
    echo "$message" >> "$ERROR_LOG"
    # 如果启用详细模式，同时输出到标准错误
    [ "$VERBOSE" = true ] && echo "$message" >&2
}

# 记录信息日志
# 功能：记录一般信息日志，仅在详细模式下显示
# 用途：用于调试和监控脚本运行状态
# 格式：时间戳 - INFO - 消息内容
log_info() {
    local message
    message="$(date '+%Y-%m-%d %H:%M:%S') - INFO - $1"
    # 仅在详细模式下输出到控制台，不写入日志文件
    [ "$VERBOSE" = true ] && echo "$message"
}

# 创建锁文件
# 功能：创建进程锁，防止多个脚本实例同时运行
# 实现机制：
#   1. 检查锁文件是否存在
#   2. 如果存在，验证锁文件中的进程ID是否有效
#   3. 处理僵尸锁文件（进程已不存在但锁文件仍在）
#   4. 创建新锁文件，写入当前进程ID
# 返回值：0成功，1失败
create_lock() {
    # 检查锁文件是否已存在
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # 验证锁文件中的进程是否仍在运行
        if ps -p "$lock_pid" > /dev/null 2>&1; then
            log_error "锁文件已存在，进程 $lock_pid 正在运行，脚本退出"
            return 1
        else
            # 发现僵尸锁文件，进程已不存在但锁文件仍在
            log_success "发现僵尸锁文件，进程 $lock_pid 已不存在，清理并继续"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 创建新锁文件，写入当前进程ID
    if echo $$ > "$LOCK_FILE"; then
        log_success "锁文件创建成功: $LOCK_FILE (PID: $$)"
        return 0
    else
        log_error "锁文件创建失败: $LOCK_FILE"
        return 1
    fi
}

# 删除锁文件
# 功能：清理锁文件，允许其他实例运行
# 调用时机：脚本正常退出时在cleanup函数中调用
remove_lock() {
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log_success "锁文件已删除: $LOCK_FILE"
    fi
}

# 检查锁文件状态
# 功能：检查是否有其他实例在运行，与create_lock类似但用于运行时检查
# 返回值：0可以继续运行，1需要退出
check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # 检查锁文件中的进程是否仍在运行
        if ps -p "$lock_pid" > /dev/null 2>&1; then
            log_error "另一个实例正在运行 (PID: $lock_pid)，当前脚本退出"
            return 1
        else
            # 发现僵尸锁文件，清理后继续
            log_success "发现僵尸锁文件，清理后继续"
            rm -f "$LOCK_FILE"
            return 0
        fi
    fi
    return 0
}

# 时间转换为分钟数
# 功能：将时间字符串（格式：HH:MM）转换为自午夜以来的分钟数
# 特殊处理：使用10进制解析，避免前导零被bash当作八进制数
# 参数：$1 - 时间字符串，格式为"HH:MM"
# 返回：分钟数
time_to_minutes() {
    local time_str="$1"
    local hour minute
    hour=$(echo "$time_str" | cut -d: -f1)
    minute=$(echo "$time_str" | cut -d: -f2)
    
    # 使用10#前缀强制10进制解析，避免前导零被当作八进制
    # 例如：08会被当作八进制数，但10#08强制为十进制8
    echo $((10#$hour * 60 + 10#$minute))
}

# 检查单个时间窗口
# 功能：检查当前时间是否在指定的时间窗口内
# 支持跨天时间窗口（如：22:00-06:00）
# 参数：
#   $1 - 时间窗口字符串，格式："开始时间-结束时间"
#   $2 - 当前小时（0-23）
#   $3 - 当前分钟（0-59）
# 返回：0在窗口内，1不在窗口内
check_single_window() {
    local window="$1"
    local current_hour="$2"
    local current_minute="$3"
    
    # 解析时间窗口，分割开始和结束时间
    local start_time end_time
    IFS='-' read -r start_time end_time <<< "$window"
    
    # 将所有时间转换为分钟数，便于比较
    local start_minutes end_minutes current_minutes
    start_minutes=$(time_to_minutes "$start_time")
    end_minutes=$(time_to_minutes "$end_time")
    current_minutes=$((10#$current_hour * 60 + 10#$current_minute))
    
    # 处理两种情况：
    if ((start_minutes<=end_minutes)) ; then
        # 不跨天：开始时间 < 结束时间（如：06:00-08:00）
        # 当前时间必须在开始和结束时间之间
        ((current_minutes>=start_minutes)) && ((current_minutes<end_minutes))
    else
        # 跨天：开始时间 > 结束时间（如：22:00-06:00）
        # 当前时间要么在开始时间之后，要么在结束时间之前
        ((current_minutes>=start_minutes)) || ((current_minutes<end_minutes))
    fi
}

# 检查是否在时间窗口内（改进版本）
# 功能：检查当前时间是否在配置的任意时间窗口内
# 支持多个时间窗口，只要在其中一个窗口内即返回成功
# 时间窗口格式：多个窗口用空格分隔，如："06:00-08:00 22:00-06:00"
# 返回：0在窗口内，1不在窗口内
is_in_time_window() {
    # 如果未配置时间窗口，始终允许运行
    [ -z "$TIME_WINDOWS" ] && return 0
    
    local current_hour current_minute
    current_hour=$(date +%H)
    current_minute=$(date +%M)
    
    # 遍历所有时间段
    for window in $TIME_WINDOWS; do
        if check_single_window "$window" "$current_hour" "$current_minute"; then
            return 0
        fi
    done
    
    return 1
}

# 生成文件列表（支持增量同步）
# 功能：扫描源目录，生成需要同步的文件列表
# 增量同步机制：基于文件修改时间，只同步新增或修改的文件
# 返回值：
#   0 - 有文件需要同步
#   1 - 生成文件列表失败
#   2 - 没有文件需要同步
generate_file_list() {
    log_success "开始生成文件列表..."
    # 清空旧文件列表，使用:命令创建空文件
    : > "$FILE_LIST"
    
    # 获取最后同步时间戳
    local last_sync_timestamp=0
    if [ -f "$LAST_SYNC_FILE" ]; then
        last_sync_timestamp=$(cat "$LAST_SYNC_FILE" 2>/dev/null || echo 0)
        log_success "读取最后同步时间: $(date -d "@$last_sync_timestamp" '+%Y-%m-%d %H:%M:%S')"
    else
        log_success "未找到同步时间戳，执行全量同步"
    fi
    
    local file_count=0
    local skipped_count=0
    
    # 根据是否有时间戳选择同步策略
    if ((last_sync_timestamp>0)) ; then
        # 增量同步：只处理修改时间晚于最后同步时间的文件
        # 使用find -print0和read -d ''处理包含空格的文件名
        while IFS= read -r -d '' file_path; do
            local file_mtime
            # 获取文件修改时间戳（Unix时间戳）
            file_mtime=$(stat -c %Y "$file_path" 2>/dev/null || echo 0)
            
            # 比较文件修改时间与最后同步时间
            if ((file_mtime>last_sync_timestamp)) ; then
                # 文件在最后同步后被修改，加入同步列表
                echo "$file_path" >> "$FILE_LIST"
                ((file_count++))
            else
                # 文件未修改，跳过
                ((skipped_count++))
            fi
        done < <(find "$SOURCE_DIR" -type f -print0 2>/dev/null)
        
        log_success "增量同步文件列表生成完成，新增/修改 $file_count 个文件，跳过 $skipped_count 个未修改文件"
    else
        # 全量同步：首次运行或时间戳文件不存在时执行
        if find "$SOURCE_DIR" -type f > "$FILE_LIST" 2>/dev/null; then
            file_count=$(wc -l < "$FILE_LIST")
            log_success "全量同步文件列表生成完成，共 $file_count 个文件"
        else
            log_error "生成文件列表失败"
            return 1
        fi
    fi
    
    # 检查是否有文件需要同步
    if [ "$file_count" -eq 0 ]; then
        log_success "没有文件需要同步"
        return 2  # 返回码2表示无文件需要同步
    fi
    
    return 0  # 返回码0表示有文件需要同步
}

# 初始化任务队列
# 功能：为多线程同步准备任务队列和进度跟踪
# 实现机制：
#   1. 清空任务队列目录中的旧文件
#   2. 创建任务总数文件
#   3. 初始化已完成任务计数器
#   4. 使用文件系统实现线程间通信
init_task_queue() {
    # 清空任务队列目录中的所有文件
    rm -f "$TASK_QUEUE"/*
    
    # 统计文件总数并写入任务总数文件
    local total_tasks
    total_tasks=$(wc -l "$FILE_LIST" | awk '{print $1}')
    echo "$total_tasks" > "$TASK_QUEUE/total_tasks"
    
    # 初始化已完成任务计数器为0
    echo 0 > "$TASK_QUEUE/completed_tasks"
    
    log_success "任务队列初始化完成，共 $total_tasks 个任务"
}

# 使用原子操作获取下一个任务
# 功能：线程安全地从任务队列中获取下一个文件路径
# 实现机制：
#   1. 使用文件锁（flock）确保原子操作
#   2. 读取已完成任务数和任务总数
#   3. 如果还有未完成任务，分配下一个任务
#   4. 更新已完成任务计数
# 返回：文件路径字符串，如果没有任务则返回空字符串
get_next_task() {
    # 使用子shell和文件锁保护共享资源访问
    (
        # 获取独占锁，文件描述符200
        flock -x 200
        
        # 读取当前进度
        local completed total
        completed=$(cat "$TASK_QUEUE/completed_tasks" 2>/dev/null || echo 0)
        total=$(cat "$TASK_QUEUE/total_tasks" 2>/dev/null || echo 0)
        
        # 检查是否还有未完成的任务
        if ((completed<total)) ; then
            # 增加已完成计数
            ((completed++))
            # 更新已完成任务计数
            echo $completed > "$TASK_QUEUE/completed_tasks"
            # 返回对应的文件路径（第completed行）
            awk "NR==$completed" "$FILE_LIST"
        else
            # 没有更多任务，返回空字符串
            echo ""
        fi
    ) 200>"$TASK_QUEUE/lock"  # 锁文件用于进程间同步
}

# 获取任务进度
# 功能：计算并返回当前同步进度
# 格式：已完成数/总数（如：15/100）
# 用途：用于日志记录和用户反馈
get_task_progress() {
    local total completed
    total=$(cat "$TASK_QUEUE/total_tasks" 2>/dev/null || echo 0)
    completed=$(cat "$TASK_QUEUE/completed_tasks" 2>/dev/null || echo 0)
    
    # 格式化输出进度
    if ((total>0)) ; then
        echo "$completed/$total"
    else
        echo "0/0"
    fi
}


# 错误分类函数
# 功能：根据rsync错误输出自动分类错误类型
# 参数：
#   $1 - rsync命令的错误输出
#   $2 - 发生错误的文件路径（用于日志）
# 返回：错误类型字符串，用于统计和重试策略
# 支持的错误类型：
#   permission_error - 权限错误
#   disk_space_error - 磁盘空间不足
#   network_error - 网络连接错误
#   file_not_found_error - 文件不存在
#   io_error - 输入输出错误
#   unknown_error - 未知错误
classify_error() {
    local error_output="$1"
    local file_path="$2"
    
    # 根据错误关键词进行分类
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

# 更新错误统计
# 功能：记录和统计同步错误信息，支持JSON格式存储
# 参数：
#   $1 - 错误类型（由classify_error函数返回）
#   $2 - 发生错误的文件路径
# 实现机制：
#   1. 如果统计文件不存在，初始化JSON结构
#   2. 使用jq工具更新JSON统计数据（如果可用）
#   3. 如果没有jq，降级为简单文本格式
#   4. 保留最近100个失败文件的记录
update_error_stats() {
    local error_type="$1"
    local file_path="$2"
    
    # 初始化错误统计文件（如果不存在）
    if [ ! -f "$ERROR_STATS_FILE" ]; then
        echo '{"total_errors": 0, "errors_by_type": {}, "failed_files": []}' > "$ERROR_STATS_FILE"
    fi
    
    # 优先使用jq工具更新JSON统计
    if command -v jq >/dev/null 2>&1; then
        # 使用jq进行原子更新：先写入临时文件，再移动
        jq --arg error_type "$error_type" \
           --arg file_path "$file_path" \
           --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
           '.total_errors += 1 |
            .errors_by_type[$error_type] = (.errors_by_type[$error_type] // 0) + 1 |
            .failed_files += [{"file": $file_path, "error_type": $error_type, "timestamp": $timestamp}] |
            .failed_files = .failed_files[-100:]' \
           "$ERROR_STATS_FILE" > "${ERROR_STATS_FILE}.tmp" && mv "${ERROR_STATS_FILE}.tmp" "$ERROR_STATS_FILE"
    else
        # 降级方案：如果没有jq，使用简单文本格式记录
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $error_type - $file_path" >> "${ERROR_STATS_FILE}.txt"
    fi
}

# 更新最后同步时间
# 功能：记录成功同步的时间戳，用于增量同步
# 实现机制：
#   1. 获取当前Unix时间戳
#   2. 写入时间戳文件
#   3. 记录可读格式的时间到日志
# 用途：下次同步时作为增量同步的基准时间
update_last_sync_time() {
    local sync_time
    # 获取当前Unix时间戳（自1970-01-01以来的秒数）
    sync_time=$(date +%s)
    # 写入时间戳文件，供增量同步使用
    echo "$sync_time" > "$LAST_SYNC_FILE"
    # 记录可读格式的时间到日志，便于人工查看
    log_success "更新上次同步时间: $(date -d "@$sync_time" '+%Y-%m-%d %H:%M:%S')"
}

# 带重试的rsync同步（改进版本，支持指数退避）
# 功能：执行rsync同步文件，支持智能重试和指数退避算法
# 参数：
#   $1 - 源文件路径
#   $2 - 目标文件路径
#   $3 - 相对路径（用于日志显示）
# 实现特性：
#   - 指数退避重试算法
#   - 根据错误类型采用不同重试策略
#   - 带宽限制支持
#   - 详细的错误统计
# 返回：success或failed:错误信息
sync_with_retry() {
    local file_path="$1"
    local dest_path="$2"
    local relative_path="$3"
    
    local retry_count=0
    local success=false
    local last_error=""
    
    # 构建rsync基础参数
    # -a: 归档模式，保持文件属性
    # -v: 详细输出
    # -z: 压缩传输
    # -c: 基于校验和跳过文件（更准确）
    # -P: 显示进度并支持断点续传
    local rsync_args="-avzcP"
    
    # 如果配置了带宽限制，添加相应参数
    if [ -n "$BANDWIDTH_LIMIT" ]; then
        rsync_args="--bwlimit=$BANDWIDTH_LIMIT $rsync_args"
        log_info "使用带宽限制: $BANDWIDTH_LIMIT"
    fi
    
    # 重试循环，支持指数退避
    while ((retry_count<MAX_RETRY_COUNT)) && [ "$success" = false ]; do
        if ((retry_count>0)); then
            # 指数退避算法：2^retry_count * BASE_RETRY_DELAY
            # 例如：第1次重试等待10秒，第2次等待20秒，第3次等待40秒
            local backoff_delay=$((BASE_RETRY_DELAY * (1 << (retry_count - 1))))
            log_success "重试 $retry_count/$MAX_RETRY_COUNT: $relative_path (等待 ${backoff_delay}秒)"
            sleep "$backoff_delay"
        fi
        
        # 执行rsync并捕获错误输出
        local error_output
        error_output=$(rsync $rsync_args "$file_path" "$dest_path" 2>&1)
        local rsync_exit_code=$?
        
        if [ $rsync_exit_code -eq 0 ]; then
            success=true
        else
            last_error="$error_output"
            retry_count=$((retry_count + 1))
            
            # 分类错误并更新统计
            local error_type
            error_type=$(classify_error "$error_output" "$file_path")
            update_error_stats "$error_type" "$file_path"
            
            # 根据错误类型决定是否继续重试
            case "$error_type" in
                "disk_space_error")
                    log_error "磁盘空间错误，停止重试: $relative_path"
                    echo "full" > "$FLAG"
                    return 1
                    ;;
                "permission_error")
                    # 权限错误通常无法通过重试解决
                    if ((retry_count>=2)) ; then
                        log_error "权限错误，跳过文件: $relative_path"
                        return 1
                    fi
                    ;;
                "network_error")
                    # 网络错误可以多尝试几次
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

# 显示错误统计报告
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
            if ((recent_failures>0)) ; then
                log_success "最近失败的文件 (最多100个):"
                jq -r '.failed_files[-5:] | .[] | "  \(.timestamp) - \(.error_type) - \(.file)"' "$ERROR_STATS_FILE" | while read -r line; do
                    log_success "$line"
                done
                if ((recent_failures>5)) ; then
                    log_success "  ... 还有 $((recent_failures - 5)) 个失败记录"
                fi
            fi
        else
            # 如果没有jq，显示简单统计
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

# 多线程rsync同步函数
multi_thread_rsync() {
    local source_dir="$1"
    local dest_dir="$2"
    local thread_count="$3"
    
    # 生成文件列表
    generate_file_list
    local generate_result=$?
    
    if ((generate_result==1)) ; then
        # 生成文件列表失败
        return 1
    elif ((generate_result==2)) ; then
        # 没有文件需要同步
        return 2
    fi
    
    # 初始化任务队列
    init_task_queue
    
    local total_files
    total_files=$(cat "$TASK_QUEUE/total_tasks")
    
    log_success "开始同步，总共 $total_files 个文件，使用 $thread_count 个线程"

    # 获取目标磁盘剩余空间（字节）
    ((free_space+=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')))
    # 去掉最小预留的可用空间
    ((available_space=free_space-MIN_FREE_SPACE_MB*1024*1024))

    # 创建进程数组
    local pids=()
    
    for ((i=1; i<=thread_count; i++)); do
        (
            local thread_id=$i
            log_success "线程 $thread_id 启动"
            
            while true; do
                # 检查flag文件状态
                local flag
                flag=$(cat "$FLAG" 2>/dev/null)
                if [ "$flag" = quit ] ; then
                    log_success "收到退出信号，退出主进程"
                    stop_daemon
                    break
                elif [ "$flag" = full ] ; then
                    log_error "目标空间不足，退出主进程"
                    stop_daemon
                    break
                elif [ "$flag" = pause ] ; then
                    # 暂停状态，继续检查
                    log_success "收到暂停信号，线程暂停，等待下一次检查"
                    sleep "$CHECK_INTERVAL"
                fi
                
                # 检查时间窗口
                until is_in_time_window ; do
                    log_success "不在时间窗口内，等待下一次检查"
                    sleep "$CHECK_INTERVAL"
                done

                # 获取下一个任务
                local file_path
                file_path=$(get_next_task)
                if [ -z "$file_path" ]; then
                    # 没有更多任务
                    log_success "线程 $thread_id 完成所有任务"
                    break
                fi

                if [ -f "$file_path" ]; then
                    # 从 file_path 左边删除 source_dir，得到相对路径
                    local relative_path="${file_path#"$source_dir"}"
                    local dest_path="$dest_dir/$relative_path"
                    local dest_dir_path
                    dest_dir_path="$(dirname "$dest_path")"
                    
                    # 检查磁盘剩余空间是否足够，可用空间 - 将要同步文件大小 > 0
                    file_size=$(stat -c %s "$file_path")
                    if (((free_space-file_size)<0)) ; then
                        log_error "目标空间不足，退出！"
                        stop_daemon
                    fi
                                        
                    # 创建目标目录
                    mkdir -p "$dest_dir_path"
                    
                    # 使用带重试的rsync同步文件
                    rsync_start_time=$(date +%s)
                    sync_result=$(sync_with_retry "$file_path" "$dest_path" "$relative_path")
                    
                    if [ "$sync_result" = "success" ]; then
                        rsync_end_time=$(date +%s)
                        rsync_duration=$(echo | awk "{print $rsync_end_time-$rsync_start_time+0.01}") # 避免速率出现 0
                        average_rate=$(echo | awk "{print $file_size/1024/$rsync_duration}")
                        available_space=$((free_space-file_size)) # 更新剩余可用空间
                        log_success "同步成功: $relative_path (进度: $(get_task_progress)), 文件大小: $((file_size/1048576)) MB, 同步耗时: $rsync_duration 秒, 平均速度: $average_rate KB/s， 目标剩余空间 $((available_space/1073741824)) GB"
                    else
                        # 提取错误信息
                        local error_msg
                        error_msg=$(echo "$sync_result" | cut -d':' -f2-)
                        log_error "同步失败: $relative_path - $error_msg"
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
            ((completed++))
        fi
    done
    
    log_success "同步任务完成: $completed/$total 个线程成功完成"
    
    # 清理临时文件
    rm -f "$FILE_LIST"
    rm -f "$TASK_QUEUE"/*
    
    return 0
}

# 检查是否有rsync进程在运行
# 功能：检查系统中是否有rsync进程正在执行
# 用途：在停止守护进程或重启时确保没有残留的rsync进程
# 返回：0有rsync进程运行，1没有rsync进程运行
is_rsync_running() {
    pgrep -x rsync >/dev/null
}

# 等待rsync进程完成
# 功能：等待所有rsync进程完成，支持超时机制
# 实现机制：
#   1. 每10秒检查一次rsync进程状态
#   2. 最大等待1小时（3600秒）
#   3. 超时后强制终止所有rsync进程
# 用途：确保在停止守护进程时所有同步操作都已安全完成
wait_for_rsync_completion() {
    local timeout=3600  # 最大等待1小时
    local waited=0
    
    # 循环检查rsync进程状态
    while is_rsync_running && ((waited<timeout)) ; do
        log_success "等待rsync进程完成... (已等待 ${waited}秒)"
        sleep 10
        ((waited+=10))
    done
    
    # 检查是否超时
    if is_rsync_running; then
        log_error "rsync进程超时，强制终止"
        # 强制终止所有rsync进程
        pkill -x rsync
        sleep 5  # 等待进程清理
    fi
}

# 显示配置信息
# 功能：以格式化方式显示当前脚本的所有配置参数
# 用途：
#   - 在干运行模式(--dry-run)下显示配置
#   - 在详细模式下启动时显示配置
#   - 调试和故障排查
show_config() {
    echo "=== rsync_multithread.sh 配置信息 ==="
    echo "版本: $VERSION"
    echo "源目录: $SOURCE_DIR"
    echo "目标目录: $DEST_DIR"
    echo "时间窗口: $TIME_WINDOWS"
    echo "并发线程数: $RSYNC_THREADS"
    echo "带宽限制: ${BANDWIDTH_LIMIT:-无限制}"
    echo "检查间隔: ${CHECK_INTERVAL}秒"
    echo "最小保留空间: ${MIN_FREE_SPACE_MB}MB"
    echo "最大重试次数: $MAX_RETRY_COUNT"
    echo "基础重试延迟: ${BASE_RETRY_DELAY}秒"
    echo "日志目录: $LOG_DIR"
    echo "配置文件: $CONFIG_FILE"
    echo "详细模式: $VERBOSE"
    echo "=================================="
}

# 主循环（改进版本）
# 功能：守护进程的主循环，控制同步任务的执行时机
# 实现逻辑：
#   1. 检查时间窗口，只在配置的时间段内执行同步
#   2. 执行多线程同步任务
#   3. 处理同步结果，更新时间戳
#   4. 在非时间窗口内等待，检查是否有残留进程
#   5. 循环执行，形成守护进程
main_loop() {
    log_success "rsync守护进程启动"
    log_info "配置信息已加载，开始主循环"
    
    # 无限循环，形成守护进程
    while true; do
        if is_in_time_window; then
            # 在时间窗口内，执行同步任务
            log_success "在时间窗口内，开始同步任务"
            
            # 执行同步并检查结果
            if multi_thread_rsync "$SOURCE_DIR" "$DEST_DIR" "$RSYNC_THREADS"; then
                # 同步成功或有文件需要同步，更新最后同步时间
                update_last_sync_time
                log_success "同步完成，等待下一次检查"
            else
                # 检查返回码
                local sync_result=$?
                if [ $sync_result -eq 2 ]; then
                    # 没有文件需要同步，仍然更新时间戳以避免重复检查
                    update_last_sync_time
                    log_success "没有文件需要同步，等待下一次检查"
                else
                    log_error "同步过程中出现错误，等待下一次检查"
                fi
            fi
            
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
# 功能：脚本退出时执行清理操作，确保系统状态干净
# 调用时机：
#   - 收到SIGINT（Ctrl+C）信号时
#   - 收到SIGTERM（kill命令）信号时
#   - 脚本正常退出时
# 清理内容：
#   1. 显示错误统计报告
#   2. 清理临时文件
#   3. 删除锁文件
#   4. 等待rsync进程完成
cleanup() {
    log_success "脚本被终止，执行清理操作"
    
    # 显示错误统计报告，便于问题排查
    show_error_report
    
    # 清理临时文件，避免残留
    rm -f "$FILE_LIST"
    rm -f "$TASK_QUEUE"/*
    
    # 删除锁文件，允许下次启动
    remove_lock
    
    # 退出脚本
    exit 0
}

# 信号处理
# 功能：设置信号陷阱，确保脚本能够优雅退出
# SIGINT: 用户按下Ctrl+C
# SIGTERM: 系统或管理员发送的终止信号
trap cleanup SIGINT SIGTERM

# 主程序入口
# 功能：脚本的入口点，按顺序执行初始化和启动流程
# 执行步骤：
#   1. 解析命令行参数
#   2. 加载配置文件
#   3. 处理干运行模式
#   4. 显示配置信息（详细模式）
#   5. 执行启动前检查
#   6. 创建锁文件
#   7. 启动主循环
main() {
    # 解析命令行参数，覆盖默认配置
    parse_arguments "$@"
    
    # 加载配置文件，应用外部配置
    load_config
    
    # 处理干运行模式（仅显示配置，不执行同步）
    if [ "$DRY_RUN" = true ]; then
        show_config
        exit 0
    fi
    
    # 在详细模式下显示配置信息
    [ "$VERBOSE" = true ] && show_config
    
    # 启动前检查：验证目录和命令可用性
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
    
    # 检查必要的系统命令
    if ! command -v flock >/dev/null 2>&1; then
        echo "错误: flock 命令不可用，请安装 util-linux 包" | tee -a "$ERROR_LOG"
        exit 1
    fi
    
    if ! command -v rsync >/dev/null 2>&1; then
        echo "错误: rsync 命令不可用，请安装 rsync 包" | tee -a "$ERROR_LOG"
        exit 1
    fi
    
    # 创建锁文件，防止多实例运行
    if ! create_lock; then
        echo "错误: 无法创建锁文件，可能已有实例在运行" | tee -a "$ERROR_LOG"
        echo "使用 --stop 参数可以停止正在运行的守护进程"
        exit 1
    fi
    
    # 启动主循环，开始守护进程
    main_loop
}

# 脚本执行检查
# 功能：确保脚本只在直接执行时运行，而不是在被source时运行
# 这样设计允许其他脚本安全地引用此脚本中的函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
