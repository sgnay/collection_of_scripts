:: windows 用来挂载 cifs 共享
:: 关闭命令输出
@echo off
:: 设置字符编码为 utf-8，gb2312 是 936
chcp 65001
:: 打开延迟变量拓展
@setlocal EnableExtensions EnableDelayedExpansion

:: --------- 配置参数，根据实际情况修改以下变量 ---------
:: 要挂载的目标IP地址
set "TARGET_IP=192.168.1.100"
:: 用户名
set "USERNAME=user01"
:: 用户密码
set "PASSWORD=123456"
:: 网络共享名和盘符映射关系
set "SHARE_DRIVE=记者:x 成片:y 播出:z"
:: ping 超时时间（毫秒）
set "PING_TIMEOUT=3000"
:: 重试间隔（秒）
set "RETRY_INTERVAL=5"
:: 重试次数
set "RETRY_COUNT=999"
:: 挂载持久化
set "PST=yes"

:: --------- 配置结束 ---------

:: 添加用户凭据到系统
cmdkey /delete:%TARGET_IP% > nul 2>&1
cmdkey /add:%TARGET_IP% /user:%USERNAME% /pass:%PASSWORD% > nul 2>&1
if !errorlevel! equ 0 (
    echo [%time%] ✓ 用户凭据添加成功
	) else (
	echo [%time%] ❌ 用户凭据添加失败
)

set /A COUNT = 1
:: 设置循环入口
:MOUNT_LOOP
echo [%time%] 正在检查 %TARGET_IP% 的可达性 - Checking reachable for %TARGET_IP% ...
ping -n 1 -w %PING_TIMEOUT% %TARGET_IP% | findstr /i "TTL" > nul 2>&1

if !errorlevel! equ 0 (
    echo [%time%] ✓ IP可达，正在尝试映射网络驱动器...
:: 循环，逐个拆解共享名和盘符的映射关系，并做映射
	for %%i in (%SHARE_DRIVE%) do (
	    for /f "tokens=1,2 delims=:" %%L in ("%%i") do (
			set "SHARE_NAME=%%L"
			set "DRIVE_LETTER=%%M"
		)
		echo [%time%] 断开盘符 ^"!DRIVE_LETTER!:^" ...
		net use !DRIVE_LETTER!: /d /y > nul 2>&1
:: net use %DRIVE_LETTER% \\%TARGET_IP%\%SHARE_NAME% %PASSWORD% /user:%USERNAME% /persistent:%PST%
		echo [%time%] 映射共享 ^"!SHARE_NAME!^" 到盘符: ^"!DRIVE_LETTER!^" ...
	    net use !DRIVE_LETTER!: \\%TARGET_IP%\!SHARE_NAME! /persistent:%PST% > nul 2>&1
		if !errorlevel! equ 0 (
            echo [%time%] ✓ 成功映射共享 ^"!SHARE_NAME!^" 到驱动器 ^"!DRIVE_LETTER!^"
:: 重命名映射的驱动器名
            reg add "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##!TARGET_IP!#!SHARE_NAME!" /v _LabelFromReg /t REG_SZ /d "!SHARE_NAME!" /f
		) else (
			echo [%time%] ❌ 映射共享 ^"!SHARE_NAME!^" 到驱动器 ^"!DRIVE_LETTER!^" 失败（可能路径错误，用户信息有误），重试...
			goto MOUNT_RETRY
		)
	)
	exit
) else (
    echo [%time%] ! IP不可达，继续监控...
	goto MOUNT_RETRY
)

: MOUNT_RETRY
set /a count += 1
IF "%COUNT%" == "%RETRY_COUNT%" (GOTO PAUSE_EXIT)
:: 等待后继续检查
timeout /t %RETRY_INTERVAL% /nobreak > nul
goto MOUNT_LOOP

: PAUSE_EXIT
echo [%time%] ❌ 出错了，按任意键退出！
pause
exit
