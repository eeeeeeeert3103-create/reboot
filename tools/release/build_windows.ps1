<#
.SYNOPSIS
  REBOOT — Release-сборка и упаковка для Windows.

.DESCRIPTION
  Запускается на Windows (локально или в CI, windows-latest). Работает в
  PowerShell 7 (pwsh) и Windows PowerShell 5.1.

    pwsh tools\release\build_windows.ps1
    pwsh tools\release\build_windows.ps1 -SkipBuild -ReleaseDir build\windows\x64\runner\Release
    pwsh tools\release\build_windows.ps1 -Dist C:\out

  Переменные окружения (необязательные):
    REBOOT_WIN_CERT_PATH        путь к .pfx для Authenticode;
    REBOOT_WIN_CERT_PASSWORD    пароль к .pfx;
    REBOOT_WIN_CERT_THUMBPRINT  альтернатива: SHA1-отпечаток сертификата в хранилище
                                CurrentUser\My или LocalMachine\My;
    REBOOT_WIN_TIMESTAMP_URL    RFC 3161 timestamp-сервер (по умолчанию DigiCert);
    REBOOT_SAVE_OBFUSCATION_MAP 1 — сохранить карту обфускации Dart в symbols;
    REBOOT_SKIP_VERIFY          1 — не запускать verify_package.py.

  Результат:
    dist\REBOOT-Windows-v<version>.zip и .zip.sha256
    dist\symbols\windows-<version>+<build>\ (split-debug-info, *.pdb) — НЕ для пользователей.
#>
[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [string]$ReleaseDir = "",
  [string]$Dist = "",
  [ValidateSet("x64", "arm64")]
  [string]$Arch = "x64"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log([string]$m)  { Write-Host "[build_windows] $m" }
function Warn([string]$m) { Write-Warning "[build_windows] $m" }
function Die([string]$m)  { Write-Error "[build_windows] ОШИБКА: $m"; exit 1 }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if (-not $Dist) { $Dist = Join-Path $Root "dist" }
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
$Dist = (Resolve-Path $Dist).Path

# --- Версия из pubspec.yaml -------------------------------------------------
$verLine = Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern '^version:\s*([^\s#]+)' | Select-Object -First 1
if (-not $verLine) { Die "не удалось прочитать version из pubspec.yaml" }
$FullVersion = $verLine.Matches[0].Groups[1].Value
$Version = $FullVersion.Split("+")[0]
$BuildNumber = "0"
if ($FullVersion.Contains("+")) { $BuildNumber = $FullVersion.Split("+")[1] }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Die "неожиданный формат версии: $FullVersion" }
Log "версия $Version (build $BuildNumber)"

$PkgName    = "REBOOT-Windows-v$Version"
$SymbolsDir = Join-Path $Dist "symbols\windows-$FullVersion"
$StageRoot  = Join-Path $Dist "staging\windows"
$Stage      = Join-Path $StageRoot $PkgName
$ZipPath    = Join-Path $Dist "$PkgName.zip"
New-Item -ItemType Directory -Force -Path $SymbolsDir | Out-Null

# --- Сборка -----------------------------------------------------------------
$Obfuscated = "да (--obfuscate --split-debug-info)"
if (-not $SkipBuild) {
  if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { Die "flutter не найден в PATH" }
  $buildArgs = @("build", "windows", "--release", "--obfuscate", "--split-debug-info=$SymbolsDir")
  if ($env:REBOOT_SAVE_OBFUSCATION_MAP -eq "1") {
    $buildArgs += "--extra-gen-snapshot-options=--save-obfuscation-map=$(Join-Path $SymbolsDir 'obfuscation-map.json')"
  }
  Log ("flutter " + ($buildArgs -join " "))
  Push-Location $Root
  try { & flutter @buildArgs; if ($LASTEXITCODE -ne 0) { Die "flutter build завершился с кодом $LASTEXITCODE" } }
  finally { Pop-Location }
  if (-not $ReleaseDir) { $ReleaseDir = Join-Path $Root "build\windows\$Arch\runner\Release" }
} else {
  if (-not $ReleaseDir) { Die "-SkipBuild требует -ReleaseDir" }
  $Obfuscated = "неизвестно (упакована готовая сборка, -SkipBuild)"
  Warn "сборка пропущена: упаковывается готовый $ReleaseDir"
}

if (-not (Test-Path (Join-Path $ReleaseDir "reboot_app.exe"))) { Die "в $ReleaseDir нет reboot_app.exe" }
$ReleaseDir = (Resolve-Path $ReleaseDir).Path

# --- Staging ----------------------------------------------------------------
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Log "копирование $ReleaseDir -> $Stage"
Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination $Stage -Recurse -Force

# PDB сохраняем в symbols (для разбора нативных сбоев), остальное просто удаляем.
$pdbs = @(Get-ChildItem -Path $Stage -Recurse -File -Filter *.pdb)
if ($pdbs.Count -gt 0) {
  $pdbDir = Join-Path $SymbolsDir "pdb"
  New-Item -ItemType Directory -Force -Path $pdbDir | Out-Null
  $pdbs | ForEach-Object { Copy-Item $_.FullName -Destination $pdbDir -Force }
  Log "PDB скопированы в symbols: $($pdbs.Count)"
}
foreach ($pattern in @("*.pdb", "*.lib", "*.exp", "*.ilk")) {
  Get-ChildItem -Path $Stage -Recurse -File -Filter $pattern | ForEach-Object {
    Log "удаляю из пакета: $($_.FullName.Substring($Stage.Length + 1))"
    Remove-Item -Force $_.FullName
  }
}

# --- Visual C++ runtime -----------------------------------------------------
function Get-PeMachine([string]$path) {
  $fs = [System.IO.File]::OpenRead($path)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Seek(0x3C, "Begin") | Out-Null
    $peOffset = $br.ReadInt32()
    $fs.Seek($peOffset + 4, "Begin") | Out-Null
    return $br.ReadUInt16()
  } finally { $fs.Dispose() }
}

$sys32 = Join-Path $env:WINDIR "System32"
if (-not [Environment]::Is64BitProcess) {
  # 32-битный процесс видит SysWOW64 вместо System32; берём настоящий System32.
  $sys32 = Join-Path $env:WINDIR "Sysnative"
}
$expectedMachine = if ($Arch -eq "arm64") { 0xAA64 } else { 0x8664 }
$RuntimeDlls = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")
foreach ($dll in $RuntimeDlls) {
  $src = Join-Path $sys32 $dll
  if (-not (Test-Path $src)) {
    Die "не найден $src. Установите Microsoft Visual C++ Redistributable 2015-2022 ($Arch) на машине сборки."
  }
  $machine = Get-PeMachine $src
  if ($machine -ne $expectedMachine) {
    Die ("{0}: архитектура 0x{1:X4}, ожидалась 0x{2:X4} ({3})" -f $src, $machine, $expectedMachine, $Arch)
  }
  Copy-Item $src -Destination $Stage -Force
  Log "runtime: $dll ($((Get-Item $src).VersionInfo.FileVersion))"
}

# --- Authenticode -----------------------------------------------------------
function Find-SignTool {
  $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
  if (Test-Path $kits) {
    $found = Get-ChildItem -Path $kits -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\x64\\' } |
      Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  return $null
}

$SignStatus = ""
$certPath = $env:REBOOT_WIN_CERT_PATH
$certThumb = $env:REBOOT_WIN_CERT_THUMBPRINT
if ($certPath -or $certThumb) {
  $signtool = Find-SignTool
  if (-not $signtool) { Die "signtool.exe не найден (нужен Windows SDK)" }
  $tsUrl = $env:REBOOT_WIN_TIMESTAMP_URL
  if (-not $tsUrl) { $tsUrl = "http://timestamp.digicert.com" }
  $signArgs = @("sign", "/fd", "SHA256", "/tr", $tsUrl, "/td", "SHA256", "/d", "REBOOT")
  if ($certPath) {
    if (-not (Test-Path $certPath)) { Die "REBOOT_WIN_CERT_PATH: файл не найден" }
    $signArgs += @("/f", $certPath)
    if ($env:REBOOT_WIN_CERT_PASSWORD) { $signArgs += @("/p", $env:REBOOT_WIN_CERT_PASSWORD) }
  } else {
    $signArgs += @("/sha1", $certThumb)
  }
  # Подписываем только свои бинарники; runtime-DLL Microsoft уже подписаны Microsoft.
  $targets = @(Get-ChildItem -Path $Stage -Recurse -File | Where-Object {
    ($_.Extension -in @(".exe", ".dll")) -and ($RuntimeDlls -notcontains $_.Name.ToLower())
  } | ForEach-Object { $_.FullName })
  Log "Authenticode: подписываю $($targets.Count) файл(ов), timestamp $tsUrl"
  & $signtool @signArgs @targets
  if ($LASTEXITCODE -ne 0) { Die "signtool sign завершился с кодом $LASTEXITCODE" }
  & $signtool verify /pa /all @targets
  if ($LASTEXITCODE -ne 0) { Die "signtool verify не прошёл" }
  $SignStatus = "Authenticode (SHA256, timestamp $tsUrl)"
} else {
  Warn "REBOOT_WIN_CERT_PATH / REBOOT_WIN_CERT_THUMBPRINT не заданы: файлы НЕ подписаны Authenticode."
  Warn "SmartScreen покажет предупреждение «Windows защитила ваш компьютер»."
  $SignStatus = "не подписано Authenticode"
}

# --- Документы пакета -------------------------------------------------------
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$readmeTemplate = Join-Path $ScriptDir "README-package.txt"
if (-not (Test-Path $readmeTemplate)) { Die "нет $readmeTemplate" }
$readme = [System.IO.File]::ReadAllText($readmeTemplate, $utf8NoBom)
$readme = $readme.Replace("@VERSION@", $Version).Replace("@BUILD@", $BuildNumber)
$readme = ($readme -replace "`r`n", "`n") -replace "`n", "`r`n"
[System.IO.File]::WriteAllText((Join-Path $Stage "README.txt"), $readme, $utf8Bom)

$policy = Join-Path $Root "docs\privacy-policy.md"
if (-not (Test-Path $policy)) { Die "нет docs\privacy-policy.md" }
Copy-Item $policy -Destination (Join-Path $Stage "PRIVACY_POLICY.md") -Force

$noticesZ = Join-Path $Stage "data\flutter_assets\NOTICES.Z"
if (-not (Test-Path $noticesZ)) { Die "нет data\flutter_assets\NOTICES.Z" }
$noticesOut = Join-Path $Stage "THIRD_PARTY_NOTICES.txt"

# Python on Windows prints to a cp1252 console by default; our messages are
# Russian, so force UTF-8 for every Python helper below.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$python = $null
foreach ($cand in @("python", "python3", "py")) {
  $c = Get-Command $cand -ErrorAction SilentlyContinue
  if ($c) { $python = $c.Source; break }
}
if ($python) {
  & $python (Join-Path $ScriptDir "extract_notices.py") $noticesZ $noticesOut
  if ($LASTEXITCODE -ne 0) { Die "extract_notices.py завершился с кодом $LASTEXITCODE" }
} else {
  # Запасной путь без Python: .NET GZipStream / DeflateStream.
  $bytes = [System.IO.File]::ReadAllBytes($noticesZ)
  $ms = New-Object System.IO.MemoryStream(, $bytes)
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) {
    $ds = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
  } elseif ($bytes.Length -ge 2 -and ($bytes[0] -band 0x0F) -eq 8 -and ((([int]$bytes[0]) * 256 + $bytes[1]) % 31) -eq 0) {
    $ms.Position = 2  # пропускаем zlib-заголовок
    $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
  } else {
    Die "неизвестный формат NOTICES.Z"
  }
  $reader = New-Object System.IO.StreamReader($ds, $utf8NoBom)
  $text = $reader.ReadToEnd(); $reader.Dispose()
  if (-not $text.Trim()) { Die "распакованный NOTICES пуст" }
  $header = "THIRD-PARTY NOTICES / ЛИЦЕНЗИИ СТОРОННИХ КОМПОНЕНТОВ`nСформировано из NOTICES.Z сборки Flutter (flutter_assets).`n=====================================================================`n`n"
  [System.IO.File]::WriteAllText($noticesOut, $header + $text, $utf8NoBom)
}

$commit = "неизвестно"; $dirty = ""
if (Get-Command git -ErrorAction SilentlyContinue) {
  $c = & git -C $Root rev-parse --short HEAD 2>$null
  if ($LASTEXITCODE -eq 0 -and $c) { $commit = $c.Trim() }
  $st = & git -C $Root status --porcelain 2>$null
  if ($st) { $dirty = " (рабочее дерево с незакоммиченными изменениями)" }
}
$versionTxt = @(
  "Product:        REBOOT",
  "Platform:       Windows ($Arch)",
  "Version:        $Version",
  "Build:          $BuildNumber",
  "Commit:         $commit$dirty",
  ("Built (UTC):    " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")),
  "Dart obfuscation: $Obfuscated",
  "Code signing:   $SignStatus",
  "VC++ runtime:   msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll (app-local)"
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $Stage "VERSION.txt"), $versionTxt + "`r`n", $utf8Bom)

# --- ZIP + SHA-256 ----------------------------------------------------------
if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
if (Test-Path "$ZipPath.sha256") { Remove-Item -Force "$ZipPath.sha256" }
Log "упаковка -> $ZipPath"
Compress-Archive -Path $Stage -DestinationPath $ZipPath -CompressionLevel Optimal
$hash = (Get-FileHash -Algorithm SHA256 -Path $ZipPath).Hash.ToLower()
[System.IO.File]::WriteAllText("$ZipPath.sha256", "$hash  $PkgName.zip`n", (New-Object System.Text.ASCIIEncoding))
Log "SHA-256: $hash"

# --- Проверка пакета --------------------------------------------------------
if ($env:REBOOT_SKIP_VERIFY -ne "1") {
  if (-not $python) { Die "для verify_package.py нужен Python 3 (или задайте REBOOT_SKIP_VERIFY=1)" }
  & $python (Join-Path $ScriptDir "verify_package.py") --platform windows $ZipPath
  if ($LASTEXITCODE -ne 0) { Die "verify_package.py нашёл нарушения (код $LASTEXITCODE)" }
}

Log "готово."
Log "  пакет:   $ZipPath"
Log "  symbols: $SymbolsDir (хранить приватно, в пакет не входят)"
Log "  подпись: $SignStatus"
