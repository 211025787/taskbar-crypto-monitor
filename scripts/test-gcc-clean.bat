@echo off
rem 干净 PATH 环境下测试 mingw64 gcc 预处理能力
set "PATH=D:\develop\msys2\mingw64\bin;C:\Windows\System32;C:\Windows"
echo int test; | D:\develop\msys2\mingw64\bin\gcc.exe -x c -E - > "%~dp0gcc-clean-out.txt" 2>&1
echo GCC_EXIT: %ERRORLEVEL%
type "%~dp0gcc-clean-out.txt"