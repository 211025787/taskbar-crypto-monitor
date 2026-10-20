# 开发工具链无人值守安装脚本：Rustup（用户级）+ VS Build Tools（VCTools 工作负载）
# 日志输出到项目根目录 .toolchain-install.log，供外部轮询安装进度
$ErrorActionPreference = "Continue"

$log = "D:\ipyProject\ai-contract\.toolchain-install.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Output $line | Tee-Object -FilePath $log -Append
}

Write-Log "=== 工具链安装开始 ==="

Write-Log "--- 步骤 1/2: 安装 Rustup（Rust 工具链管理器，用户级） ---"
winget install Rustlang.Rustup --accept-source-agreements --accept-package-agreements --silent 2>&1 | Tee-Object -FilePath $log -Append
Write-Log "Rustup 安装退出码: $LASTEXITCODE"

Write-Log "--- 步骤 2/2: 安装 VS Build Tools 2022（C++ 工作负载，含 MSVC v143 + Windows SDK） ---"
winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" --accept-source-agreements --accept-package-agreements 2>&1 | Tee-Object -FilePath $log -Append
Write-Log "BuildTools 安装退出码: $LASTEXITCODE"

Write-Log "=== 工具链安装结束 ==="