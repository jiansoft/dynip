<#
.SYNOPSIS
    把 scripts\build.ps1 產出的 ARMv7 執行檔部署到 Raspberry Pi 3 的 /opt/dynip。

.DESCRIPTION
    對應手動流程：scp 到 /tmp → control.sh update → 驗證。

      1. 本機預檢：直接讀 ELF header 確認執行檔是 32-bit little-endian ARM。
         Zig 的產物沒有 Go 那種內嵌 buildinfo，所以改用這個最底層也最可靠的檢查，
         避免把 aarch64 版（dynip_linux_arm64）誤傳成 armv7。
      2. scp 到 /tmp —— control.sh 的 move 只認 <上傳目錄>/<uname 推出的檔名>，
         檔名不對只會回報「找不到可部署的執行檔」。
      3. -WithConfig 時另外同步 app.json 與 .env（move 只搬執行檔）。
      4. ssh 執行 control.sh update（stop → 等待舊程序結束 → move → start）。
      5. 驗證：pid file 指向的程序活著、dashboard 埠有回應、stdout log 尾巴。

    這支腳本不建置，要連建置一起做請加 -Build（會呼叫同目錄的 build.ps1）。
    回滾：move 會把舊執行檔備份成 <名稱>.<時間戳> 並拿掉執行權限，
    改名回去再 ./control.sh restart 即可。

.PARAMETER Target
    SSH 目標，預設 pi@192.168.111.138。

.PARAMETER IdentityFile
    SSH 私鑰路徑，預設 $env:USERPROFILE\.ssh\138.key。

.PARAMETER SshPort
    SSH 連接埠，預設 22。

.PARAMETER Binary
    要部署的執行檔，預設 zig-out\bin\dynip_linux_armv7。

.PARAMETER RemoteBase
    Pi 上的部署目錄，預設 /opt/dynip。

.PARAMETER DashboardPort
    驗證時要打的 dashboard 埠，預設 9003（對應 app.json 的 dashboard.port）。
    設為 0 表示不檢查。

.PARAMETER WithConfig
    一併上傳 app.json 與 .env。
    注意：正式機的這兩個檔案帶有各家 DDNS 服務的 token／密碼，
    內容未必與開發機相同，確定要覆蓋才加這個參數。

.PARAMETER Build
    部署前先執行 scripts\build.ps1。

.PARAMETER SkipVerify
    略過部署後的驗證（仍會啟動服務）。

.EXAMPLE
    .\scripts\deploy-armv7.ps1

.EXAMPLE
    .\scripts\deploy-armv7.ps1 -Build
#>
[CmdletBinding()]
param(
    [string]$Target = 'pi@192.168.111.138',
    [string]$IdentityFile = "$env:USERPROFILE\.ssh\138.key",
    [int]$SshPort = 22,
    [string]$Binary,
    [string]$RemoteBase = '/opt/dynip',
    [int]$DashboardPort = 9003,
    [switch]$WithConfig,
    [switch]$Build,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 這支腳本放在 scripts\ 底下，專案根目錄是它的上一層。
$ProjectDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$BinaryName = 'dynip_linux_armv7'

if ([string]::IsNullOrWhiteSpace($Binary)) {
    $Binary = Join-Path $ProjectDir "zig-out\bin\$BinaryName"
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "指令失敗（exit $LASTEXITCODE）：$Command $($Arguments -join ' ')"
    }
}

# 讀 ELF header 判斷架構。只需要前 20 個 byte：
#   0..3   魔術字 0x7F 'E' 'L' 'F'
#   4      EI_CLASS   1=32-bit、2=64-bit
#   5      EI_DATA    1=little-endian
#   16..17 e_type     2=EXEC、3=DYN（PIE）
#   18..19 e_machine  40(0x28)=ARM、183(0xB7)=AArch64
function Assert-Armv7Elf {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [byte[]]::new(20)
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Read($bytes, 0, 20) -ne 20) { throw "$Path 太小，不是有效的 ELF 檔" }
    }
    finally {
        $stream.Dispose()
    }

    if ($bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
        throw "$Path 不是 ELF 檔（Windows 的 .exe 或 arm64 以外的產物都會落在這裡）"
    }
    if ($bytes[4] -ne 1) {
        throw "$Path 是 64-bit ELF；Raspberry Pi 3 跑的是 32-bit armv7l，要用 dynip_linux_armv7"
    }
    if ($bytes[5] -ne 1) { throw "$Path 不是 little-endian ELF" }

    $eType = [BitConverter]::ToUInt16($bytes, 16)
    if ($eType -ne 2 -and $eType -ne 3) { throw "$Path 不是可執行檔（e_type=$eType）" }

    $machine = [BitConverter]::ToUInt16($bytes, 18)
    if ($machine -ne 40) {
        $name = if ($machine -eq 183) { 'AArch64（arm64 版本，傳錯檔了）' } else { "e_machine=$machine" }
        throw "$Path 的架構不是 ARM：$name"
    }
}

# ssh/scp 共用參數：BatchMode 讓沒有金鑰時直接失敗，而不是卡在互動式密碼提示。
$SshArgs = @('-p', "$SshPort", '-o', 'BatchMode=yes')
$ScpArgs = @('-P', "$SshPort", '-o', 'BatchMode=yes')
if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
    if (-not (Test-Path -LiteralPath $IdentityFile)) {
        throw "找不到 SSH 私鑰：$IdentityFile"
    }
    $SshArgs = @('-i', $IdentityFile) + $SshArgs
    $ScpArgs = @('-i', $IdentityFile) + $ScpArgs
}

function Invoke-Remote {
    param([Parameter(Mandatory = $true)][string]$Script)
    & ssh @SshArgs $Target $Script
}

if ($Build) {
    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'build.ps1 失敗' }
    Write-Host ''
}

# --- 1. 本機預檢 -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Binary)) {
    throw "找不到執行檔：$Binary（先跑 .\scripts\build.ps1，或用 -Build）"
}

Write-Host '本機預檢...' -ForegroundColor Cyan
Assert-Armv7Elf -Path $Binary
$item = Get-Item -LiteralPath $Binary
$size = [Math]::Round($item.Length / 1KB)
Write-Host "  BINARY   $Binary ($size KB, $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
Write-Host '  TARGET   ELF 32-bit LSB, ARM'

# --- 2. 遠端預檢 -------------------------------------------------------------
$remoteInfo = Invoke-Remote "uname -m; test -f $RemoteBase/control.sh && echo CONTROL_OK || echo CONTROL_MISSING"
if ($LASTEXITCODE -ne 0) { throw "SSH 連線失敗：$Target" }
$arch = ($remoteInfo | Select-Object -First 1).Trim()
if ($arch -ne 'armv7l') { throw "遠端架構是 $arch，不是 armv7l" }
if ($remoteInfo -notcontains 'CONTROL_OK') { throw "遠端找不到 $RemoteBase/control.sh" }
Write-Host "  REMOTE   $Target ($arch, $RemoteBase)"
Write-Host ''

# --- 3. 上傳 ----------------------------------------------------------------
Write-Host '上傳執行檔...' -ForegroundColor Cyan
Invoke-Checked scp @ScpArgs $Binary "${Target}:/tmp/$BinaryName"

if ($WithConfig) {
    Write-Host '上傳 app.json 與 .env...' -ForegroundColor Cyan
    foreach ($name in 'app.json', '.env') {
        $path = Join-Path $ProjectDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "找不到 $path"
        }
        Invoke-Checked scp @ScpArgs $path "${Target}:$RemoteBase/$name"
    }
}
Write-Host ''

# --- 4. 部署 ----------------------------------------------------------------
Write-Host 'control.sh update...' -ForegroundColor Cyan
Invoke-Remote "cd $RemoteBase && ./control.sh update"
if ($LASTEXITCODE -ne 0) { throw 'control.sh update 失敗' }
Write-Host ''

if ($SkipVerify) {
    Write-Host '已略過驗證（-SkipVerify）。' -ForegroundColor Yellow
    return
}

# --- 5. 驗證 ----------------------------------------------------------------
Write-Host '驗證中（等待服務起來）...' -ForegroundColor Cyan
Start-Sleep -Seconds 8

# 服務沒有 systemd 看管，pid file 指向的程序是否真的活著就是唯一的存活依據。
$verify = @"
echo "--- process ---"
if [ -f $RemoteBase/dynip.pid ]; then
  pid=`$(cat $RemoteBase/dynip.pid)
  ps -p `$pid -o pid,etime,cmd --no-headers 2>/dev/null || echo "PID_DEAD `$pid"
else
  echo 'PID_FILE_MISSING'
fi
echo "--- dashboard ---"
if [ "$DashboardPort" -gt 0 ]; then
  curl -s -o /dev/null -m 5 -w 'dashboard http=%{http_code}\n' http://127.0.0.1:$DashboardPort/ || echo 'dashboard 沒有回應'
else
  echo 'skipped'
fi
echo "--- stdout log ---"
tail -n 5 $RemoteBase/log/general_stdout.log 2>/dev/null
"@
$result = Invoke-Remote $verify
$result | ForEach-Object { Write-Host "  $_" }

$text = $result -join "`n"
$problems = @()
if ($text -match 'PID_DEAD|PID_FILE_MISSING') { $problems += '服務程序沒有活著' }
if ($text -notmatch "$BinaryName") { $problems += "執行中的程序不是 $BinaryName" }
if ($DashboardPort -gt 0 -and $text -notmatch 'dashboard http=200') { $problems += "dashboard($DashboardPort) 沒有回 200" }

Write-Host ''
if ($problems.Count -gt 0) {
    Write-Host '部署完成但驗證有問題：' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "回滾：ssh $Target `"cd $RemoteBase && ls -t $BinaryName.* | head -1`"，把該備份改名回 $BinaryName 後 ./control.sh restart" -ForegroundColor Yellow
    exit 1
}

Write-Host "部署成功：$Target`:$RemoteBase/$BinaryName" -ForegroundColor Green
