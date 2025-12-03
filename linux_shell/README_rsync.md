# rsync_multithread.sh v2.0.0 使用说明

## 概述

`rsync_multithread.sh` 是一个功能强大的多线程 rsync 同步守护进程，支持时间窗口控制、带宽限制、智能重试等企业级特性。

## 主要特性

- ✅ **多线程并发同步**：可配置线程数，提高同步效率
- ✅ **时间窗口控制**：支持多个时间段，避免在工作时间影响性能
- ✅ **智能重试机制**：指数退避算法，根据错误类型采用不同策略
- ✅ **带宽限制**：可设置传输速度上限，避免网络拥堵
- ✅ **配置文件支持**：支持外部配置文件，便于管理
- ✅ **详细日志记录**：分类记录成功、错误和信息日志
- ✅ **错误统计报告**：自动生成错误统计和分析报告
- ✅ **进程锁机制**：防止多实例运行冲突
- ✅ **优雅退出**：支持信号处理，自动清理资源
- ✅ **增量同步**：基于文件修改时间的智能增量同步，避免重复传输

## 快速开始

### 1. 基本使用

```bash
# 使用默认配置启动
./rsync_multithread.sh

# 指定源目录和目标目录
./rsync_multithread.sh -s /path/to/source -d /path/to/destination

# 设置8个线程，带宽限制5MB/s
./rsync_multithread.sh -t 8 -b 5M

# 启用详细输出模式
./rsync_multithread.sh -v
```

### 2. 使用配置文件

```bash
# 复制示例配置文件
cp rsync_daemon.conf.example rsync_daemon.conf

# 编辑配置文件
vim rsync_daemon.conf

# 使用配置文件启动
./rsync_multithread.sh --config rsync_daemon.conf
```

### 3. 管理守护进程

```bash
# 查看配置（不执行同步）
./rsync_multithread.sh --dry-run -v

# 停止运行中的守护进程
./rsync_multithread.sh --stop

# 查看帮助信息
./rsync_multithread.sh --help
```

## 命令行参数

| 参数 | 长参数 | 说明 | 默认值 |
|------|--------|------|--------|
| `-c` | `--config` | 配置文件路径 | `./rsync_daemon.conf` |
| `-s` | `--source` | 源目录路径 | `/home/sgnay/Downloads/android/` |
| `-d` | `--dest` | 目标目录路径 | `/home/sgnay/Downloads/android_bak/` |
| `-t` | `--threads` | 并发线程数 | `4` |
| `-w` | `--windows` | 时间窗口 | `"06:00-08:00 12:00-13:00 14:00-18:20 22:00-23:30"` |
| `-b` | `--bandwidth` | 带宽限制 | 无限制 |
| `-i` | `--interval` | 检查间隔(秒) | `300` |
| `-r` | `--retry` | 最大重试次数 | `3` |
| `-m` | `--min-space` | 最小保留空间(MB) | `4096` |
| `-v` | `--verbose` | 详细输出模式 | `false` |
| `-h` | `--help` | 显示帮助信息 | - |
| | `--dry-run` | 仅显示配置，不执行同步 | `false` |
| | `--stop` | 停止正在运行的守护进程 | - |

## 配置文件格式

```bash
# 基本配置
SOURCE_DIR="/path/to/source"
DEST_DIR="/path/to/destination"

# 时间窗口配置
TIME_WINDOWS="06:00-08:00 12:00-14:00 18:00-22:00"

# 性能配置
RSYNC_THREADS=4
BANDWIDTH_LIMIT="10M"  # 10MB/s，留空表示无限制

# 时间和空间配置
CHECK_INTERVAL=300      # 检查间隔(秒)
MIN_FREE_SPACE_MB=4096  # 最小保留空间(MB)

# 重试配置
MAX_RETRY_COUNT=3       # 最大重试次数
BASE_RETRY_DELAY=10     # 基础重试延迟(秒)

# 日志配置
LOG_DIR="./rsync_daemon"
```

## 时间窗口格式

时间窗口格式为 `"开始时间-结束时间"`，多个时间段用空格分隔：

```bash
# 单个时间段
TIME_WINDOWS="06:00-08:00"

# 多个时间段
TIME_WINDOWS="06:00-08:00 12:00-14:00 18:00-22:00"

# 跨天时间段
TIME_WINDOWS="22:00-06:00"
```

## 带宽限制格式

支持以下格式：
- `"10M"` - 10MB/s
- `"100K"` - 100KB/s
- `"1G"` - 1GB/s
- 留空 - 无限制

## 日志文件

脚本会在日志目录下创建以下文件：

- `success.log` - 成功操作日志
- `error.log` - 错误日志
- `error_stats.json` - 错误统计（JSON格式）
- `last_sync_time` - 最后同步时间戳（用于增量同步）
- `rsync_daemon.lock` - 进程锁文件

## 错误类型

脚本会自动分类以下错误类型：

- `disk_space_error` - 磁盘空间不足
- `permission_error` - 权限错误
- `network_error` - 网络连接错误
- `file_not_found_error` - 文件不存在
- `io_error` - 输入输出错误
- `unknown_error` - 未知错误

## 增量同步机制

脚本支持基于文件修改时间的智能增量同步：

### 工作原理
1. **时间戳记录**：每次成功同步后，脚本会在 `last_sync_time` 文件中记录当前时间戳
2. **文件筛选**：下次同步时，只会处理修改时间晚于最后同步时间戳的文件
3. **自动切换**：
   - 首次运行或时间戳文件不存在时，执行全量同步
   - 后续运行时，自动执行增量同步
   - 如果没有文件需要同步，会记录相应日志并更新时间戳

### 优势
- **效率提升**：避免重复传输未修改的文件
- **带宽节省**：只传输有变化的文件
- **时间优化**：大幅缩短同步时间
- **智能识别**：基于文件系统时间戳，准确判断文件变化

### 日志示例
```
2024-01-01 10:00:00 - SUCCESS - 读取最后同步时间: 2024-01-01 06:00:00
2024-01-01 10:00:01 - SUCCESS - 增量同步文件列表生成完成，新增/修改 15 个文件，跳过 1250 个未修改文件
```

## 重试策略

不同错误类型采用不同的重试策略：

- **磁盘空间错误**：立即停止，不重试
- **权限错误**：最多重试2次
- **网络错误**：可以使用全部重试次数
- **其他错误**：使用默认重试策略

重试延迟采用指数退避算法：`2^retry_count * BASE_RETRY_DELAY`

## 监控和维护

### 查看运行状态

```bash
# 检查进程是否运行
ps aux | grep rsync_multithread

# 查看锁文件
cat ./rsync_daemon/rsync_daemon.lock

# 查看最近的成功日志
tail -f ./rsync_daemon/success.log

# 查看最近的错误日志
tail -f ./rsync_daemon/error.log
```

### 错误统计报告

脚本会自动生成错误统计报告，包含：
- 总错误数
- 按错误类型分类的统计
- 最近失败的文件列表（最多100个）

### 清理和重启

```bash
# 停止守护进程
./rsync_multithread.sh --stop

# 清理临时文件（可选）
rm -f ./rsync_daemon/task_queue/*
rm -f ./rsync_daemon/file_list.txt

# 重新启动
./rsync_multithread.sh
```

## 故障排除

### 常见问题

1. **权限错误**
   ```bash
   # 确保脚本有执行权限
   chmod +x rsync_multithread.sh
   
   # 确保对源目录有读权限，对目标目录有写权限
   ```

2. **flock 命令不可用**
   ```bash
   # Ubuntu/Debian
   sudo apt-get install util-linux
   
   # CentOS/RHEL
   sudo yum install util-linux
   ```

3. **rsync 命令不可用**
   ```bash
   # Ubuntu/Debian
   sudo apt-get install rsync
   
   # CentOS/RHEL
   sudo yum install rsync
   ```

4. **配置文件权限问题**
   ```bash
   # 确保配置文件可读
   chmod 644 rsync_daemon.conf
   ```

5. **JSON错误统计文件损坏**
   
   当脚本异常中断时，可能会出现JSON格式错误。脚本会自动检测并修复，也可以手动修复：
   
   ```bash
   # 使用修复工具
   ./fix_error_stats.sh
   
   # 或者手动删除重建
   rm -f ./rsync_daemon/error_stats.json
   ```
   
   脚本具有以下自动恢复机制：
   - **自动检测**：启动时验证JSON文件格式
   - **自动备份**：损坏文件会自动备份
   - **自动修复**：重新初始化为正确的JSON格式
   - **并发安全**：使用文件锁防止并发写入冲突

### 调试模式

使用详细模式进行调试：

```bash
./rsync_multithread.sh -v --dry-run
```

这将显示详细的配置信息和运行状态，便于问题排查。

## 版本信息

- **当前版本**：v2.0.0
- **主要更新**：
  - 修复时间格式处理问题
  - 添加配置文件支持
  - 实现指数退避重试
  - 添加带宽限制功能
  - 完善错误处理机制
  - 优化用户界面和日志系统

## 许可证

本脚本遵循 MIT 许可证，可自由使用和修改。