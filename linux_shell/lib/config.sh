#!/bin/bash
# 配置加载模块

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0

    log_success "加载配置文件: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)      CONFIG_FILE="$2"; shift 2 ;;
            -s|--source)      SOURCE_DIR="$2"; shift 2 ;;
            -d|--dest)        DEST_DIR="$2"; shift 2 ;;
            -t|--threads)     RSYNC_THREADS="$2"; shift 2 ;;
            -w|--windows)     TIME_WINDOWS="$2"; shift 2 ;;
            -b|--bandwidth)   BANDWIDTH_LIMIT="$2"; shift 2 ;;
            -i|--interval)    CHECK_INTERVAL="$2"; shift 2 ;;
            -r|--retry)       MAX_RETRY_COUNT="$2"; shift 2 ;;
            -m|--min-space)   MIN_FREE_SPACE_MB="$2"; shift 2 ;;
            -v|--verbose)     VERBOSE=true; shift ;;
            -h|--help)        show_help; exit 0 ;;
            --dry-run)        DRY_RUN=true; shift ;;
            --stop)           stop_daemon ;;
            *)                echo "未知选项: $1"; show_help; exit 1 ;;
        esac
    done
}

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
    echo "最大重试延迟: ${MAX_RETRY_DELAY}秒"
    echo "日志目录: $LOG_DIR"
    echo "配置文件: $CONFIG_FILE"
    echo "详细模式: $VERBOSE"
    echo "试运行模式: ${DRY_RUN:-false}"
    echo "=================================="
}

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

示例:
    $0 -s /home/user/data -d /backup/data -t 8 -b 5M
    $0 --config /etc/rsync_daemon.conf
    $0 --stop

EOF
}
