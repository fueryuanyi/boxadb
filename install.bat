@echo off
REM ---------------------------------------------------------------------
REM BoxADB WiFi 桥接一键安装（Windows 10/11 64-bit）
REM
REM 推荐用法：下载 Releases 里的 boxadb-windows.zip，解压后双击本文件。
REM zip 已内含 boxadb-bridge.exe 与 AppIcon.ico，走同目录复制、无需联网。
REM 若单独保存了本 bat（没有同目录文件），会自动拉 zip 解压兜底。
REM
REM 效果：
REM   - 安装到 %LOCALAPPDATA%\boxadb\
REM   - 对 exe/启动器执行 Unblock-File，删除"来自网络"标记(MOTW)，
REM     从而规避 SmartScreen 的"Windows 已保护你的电脑/仍要运行"蓝盾
REM   - 生成「启动桥接.bat」，双击即起、关 cmd 窗口即断
REM   - 桌面建带图标的快捷方式「BoxADB 桥接.lnk」
REM
REM 卸载：删除 %LOCALAPPDATA%\boxadb\ 和桌面快捷方式即可。
REM
REM 注意：本文件里所有含圆括号的 PowerShell 命令都放在顶层或 goto 之后，
REM       不能放进 if (...) 代码块，否则 cmd 会把命令内的 ) 误当块结束符。
REM ---------------------------------------------------------------------
setlocal EnableExtensions
chcp 65001 >nul

set "SRC_DIR=%~dp0"
set "APP_DIR=%LOCALAPPDATA%\boxadb"
set "BIN=%APP_DIR%\boxadb-bridge.exe"
set "LAUNCHER=%APP_DIR%\启动桥接.bat"
set "ICON=%APP_DIR%\AppIcon.ico"
set "DESKTOP_LNK=%USERPROFILE%\Desktop\BoxADB 桥接.lnk"

if not exist "%APP_DIR%" mkdir "%APP_DIR%"

REM 1) 取 exe + ico：同目录有就复制；没有就下载 boxadb-windows.zip 解压兜底
if exist "%SRC_DIR%boxadb-bridge.exe" goto :copylocal

echo 未在 install.bat 同目录找到打包文件，改为下载 boxadb-windows.zip 并解压...
curl -fL -o "%TEMP%\boxadb-windows.zip" "https://github.com/wukongdaily/boxadb/releases/latest/download/boxadb-windows.zip"
if errorlevel 1 goto :dlfail
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Join-Path $env:TEMP 'boxadb-win'; Expand-Archive -LiteralPath (Join-Path $env:TEMP 'boxadb-windows.zip') -DestinationPath $d -Force; Copy-Item -LiteralPath (Join-Path $d 'boxadb-bridge.exe') -Destination '%BIN%' -Force; Copy-Item -LiteralPath (Join-Path $d 'AppIcon.ico') -Destination '%ICON%' -Force"
if errorlevel 1 goto :unzfail
goto :setup

:copylocal
copy /y "%SRC_DIR%boxadb-bridge.exe" "%BIN%" >nul
copy /y "%SRC_DIR%AppIcon.ico"       "%ICON%" >nul
goto :setup

:setup
REM 2) 生成启动器：cmd 前台跑 exe，关窗口 CTRL_CLOSE 直接终止
>  "%LAUNCHER%" echo @echo off
>> "%LAUNCHER%" echo chcp 65001 ^>nul
>> "%LAUNCHER%" echo echo 正在启动 BoxADB 桥接（关闭本窗口即断开）...
>> "%LAUNCHER%" echo echo.
>> "%LAUNCHER%" echo "%BIN%"
>> "%LAUNCHER%" echo echo.
>> "%LAUNCHER%" echo echo 桥接已退出，端口已释放。
>> "%LAUNCHER%" echo pause

REM 3) 关键：删除 MOTW（"来自网络"标记），SmartScreen 之后不再拦 exe
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%BIN%' -EA 0; Unblock-File -LiteralPath '%LAUNCHER%' -EA 0; if(Test-Path '%ICON%'){Unblock-File -LiteralPath '%ICON%' -EA 0}"

REM 4) 桌面快捷方式：指向启动器 bat，图标用 AppIcon.ico
powershell -NoProfile -Command "$w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut('%DESKTOP_LNK%'); $s.TargetPath='%LAUNCHER%'; $s.WorkingDirectory='%APP_DIR%'; $s.IconLocation='%ICON%,0'; $s.Description='BoxADB WiFi bridge'; $s.Save()"

echo.
echo [完成] 已安装：
echo        二进制：  %BIN%
echo        启动器：  %LAUNCHER%
if exist "%DESKTOP_LNK%" echo        桌面快捷方式：%DESKTOP_LNK%（带图标）
echo.
echo 用法：
echo    1）双击桌面「BoxADB 桥接」- 弹 cmd 窗口跑桥（已去蓝盾）
echo    2）打开 https://wukongdaily.github.io/boxadb/ 输盒子 IP - 点连接
echo    3）用完关掉 cmd 窗口，端口自动释放
echo.
pause
exit /b 0

:dlfail
echo [错误] 下载 boxadb-windows.zip 失败，请检查网络。
pause
exit /b 1

:unzfail
echo [错误] 解压 boxadb-windows.zip 失败。
pause
exit /b 1
