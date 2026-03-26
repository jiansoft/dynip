# 遇到非終止型錯誤時，直接當成真正錯誤中止腳本。
$ErrorActionPreference = 'Stop'

# 開啟較嚴格的語法檢查，像是未宣告變數等問題會更早被抓到。
Set-StrictMode -Version Latest

# `$MyInvocation.MyCommand.Path` 是目前這支 ps1 的完整路徑。
# `Split-Path -Parent` 取出它所在的資料夾，也就是專案根目錄。
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 這裡把建置常用設定集中放在前面，後面比較好維護。
$BinName = 'dynip'
$OutDir = Join-Path $ProjectDir 'zig-out\bin'
$Optimize = 'ReleaseFast'
$FallbackZig = 'D:\Runtime\zig\0.16.0\zig.exe'

function Resolve-ZigCommand {
    # `Get-Command zig` 會去找目前環境能不能執行 `zig`。
    # 找得到的話，回傳實際執行檔路徑。
    $zig = Get-Command zig -ErrorAction SilentlyContinue
    if ($zig) {
        return $zig.Source
    }

    # 如果 PATH 找不到，就退一步改用這台機器上的固定路徑。
    if (Test-Path $FallbackZig) {
        return $FallbackZig
    }

    # 兩邊都找不到就直接丟錯，讓外層 catch 處理。
    throw "Zig is not installed or not in PATH. Checked PATH and $FallbackZig"
}

function Build-Target {
    # `param(...)` 是 PowerShell 函式的參數宣告區。
    # `[Parameter(Mandatory = $true)]` 代表呼叫這個函式時一定要傳入該參數。
    # `[string]` 代表這個參數的型別是字串。
    param(
        # 要執行的 Zig 程式路徑，例如 `zig` 或完整 exe 路徑。
        [Parameter(Mandatory = $true)][string]$ZigCmd,
        # Zig 的 target 名稱，例如 `aarch64-linux`。
        [Parameter(Mandatory = $true)][string]$Target,
        # `zig build` 產生的原始輸出檔，相對於專案根目錄的路徑。
        [Parameter(Mandatory = $true)][string]$SourceRelativePath,
        # 複製到 `zig-out\bin\` 之後要使用的檔名。
        [Parameter(Mandatory = $true)][string]$DestFileName,
        # 顯示在主控台上的進度標籤，例如 `3/4`。
        [Parameter(Mandatory = $true)][string]$Step
    )

    # 在主控台印出目前進度與 target 名稱。
    Write-Host "[$Step] Building $Target..."

    # `&` 是 PowerShell 的呼叫運算子。
    # 這裡代表「執行 `$ZigCmd` 這個外部程式」，後面接它的參數。
    # `-Dstrip=true` 代表 release 產物要移除 debug symbols，
    # 讓正式部署用的檔案體積更小。
    & $ZigCmd 'build' "-Dtarget=$Target" "-Doptimize=$Optimize" '-Dstrip=true'

    # 外部程式執行完後，可用 `$LASTEXITCODE` 取得上一個 process 的結束碼。
    # 非 0 一般代表失敗。
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for target: $Target"
    }

    # `Join-Path` 用來安全地組路徑，比自己手寫 `\` 穩定。
    $sourcePath = Join-Path $ProjectDir $SourceRelativePath
    if (-not (Test-Path $sourcePath)) {
        throw "Build finished, but output was not found: $sourcePath"
    }

    # 把 Zig 預設先產出的主執行檔
    # 再複製成比較清楚的跨平台檔名，並且一樣放在 `zig-out\bin\`。
    $destPath = Join-Path $OutDir $DestFileName
    $destDir = Split-Path -Parent $destPath

    # 有些 PowerShell / Windows 組合在 `Copy-Item` 寫入檔案時，
    # 如果目的地資料夾狀態不如預期，會直接噴出
    # "Could not find a part of the path"。
    # 這裡保險起見，每次複製前都明確確保父資料夾存在。
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }

    # 明確指定 `-Path` 與 `-Destination`，避免 PowerShell 自己猜參數位置。
    Copy-Item -Path $sourcePath -Destination $destPath -Force
    Write-Host "Built $destPath"
}

# 先切到專案目錄，確保相對路徑都以這裡為基準。
Push-Location $ProjectDir
try {
    # 先決定這次要使用哪一支 Zig。
    $ZigCmd = Resolve-ZigCommand

    Write-Host '[1/4] Zig version:'

    # 直接呼叫 `zig version` 取得版本字串。
    $zigVersion = & $ZigCmd 'version'
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to read zig version.'
    }
    Write-Host "  - zig $zigVersion"

    Write-Host '[2/4] Preparing output directory...'

    # 如果舊的 `zig-out\bin` 已存在，就整個刪掉重建，避免舊檔混進來。
    if (Test-Path $OutDir) {
        Remove-Item -Recurse -Force $OutDir
    }

    # 重新建立乾淨的輸出目錄。
    New-Item -ItemType Directory -Path $OutDir | Out-Null

    # 這個腳本現在只建一個 target：Linux ARM64。
    Build-Target -ZigCmd $ZigCmd -Target 'aarch64-linux' -SourceRelativePath "zig-out\\bin\\$BinName" -DestFileName "${BinName}_linux_arm64" -Step '3/4'

    Write-Host '[4/4] Done.'
    Write-Host 'Output files:'

    # 只列出 `zig-out\bin` 下面的檔名，方便快速確認結果。
    Get-ChildItem -Name $OutDir

    # 腳本成功結束時，明確回傳 0。
    exit 0
}
catch {
    # `$_` 代表目前 catch 到的錯誤物件。
    Write-Error $_
    exit 1
}
finally {
    # 不管成功或失敗，都把工作目錄切回原本的位置。
    Pop-Location
}
