param(
  [string]$InstallDir = "C:\Program Files\Multivideo\Playout",
  [string]$PlayoutHome = "C:\ProgramData\Multivideo\Playout",
  [string]$Bind = "127.0.0.1:8091",
  [string]$PublicBaseUrl = "http://127.0.0.1:8091",
  [string]$ControlPlaneUrl = "https://license.vorbio.me",
  [string]$LicenseRequired = "true",
  [string]$FfmpegPath = "",
  [string]$FfprobePath = "",
  [string]$TmdbApiKey = "",
  [string]$ReleaseId = "",
  [string]$ServiceName = "MultivideoPlayoutRuntime",
  [string]$DisplayName = "Multivideo Playout Runtime",
  [string]$SourceDir = "",

  [ValidateSet("Debug", "Release")]
  [string]$Configuration = "Release",

  [switch]$Build,
  [switch]$NoStart,
  [switch]$NoElevate
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Join-Args {
  param([string[]]$Items)
  return ($Items | ForEach-Object {
    if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
  }) -join ' '
}

function Invoke-Sc {
  param([string[]]$Arguments)
  & sc.exe @Arguments | Write-Host
  if ($LASTEXITCODE -ne 0) {
    throw "sc.exe failed: $($Arguments -join ' ')"
  }
}

function Normalize-BoolSetting {
  param([string]$Value, [string]$DefaultValue = "true")
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $DefaultValue
  }
  $normalized = $Value.Trim().ToLowerInvariant()
  if ($normalized -in @("1", "true", "yes", "y", "on")) {
    return "true"
  }
  if ($normalized -in @("0", "false", "no", "n", "off")) {
    return "false"
  }
  throw "Invalid boolean value: $Value"
}

function Set-Shortcut {
  param([string]$ShortcutPath, [string]$TargetPath, [string]$WorkingDirectory, [string]$IconPath = "")
  try {
    $shortcutDir = Split-Path -Parent $ShortcutPath
    New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    if (-not [string]::IsNullOrWhiteSpace($IconPath) -and (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
      $shortcut.IconLocation = "$IconPath,0"
    } else {
      $shortcut.IconLocation = "$TargetPath,0"
    }
    $shortcut.Save()
  } catch {
    Write-Warning "Could not update shortcut ${ShortcutPath}: $($_.Exception.Message)"
  }
}

function Test-IsUnderPath {
  param([string]$Path, [string]$Root)
  if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
    return $false
  }
  try {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Resolve-BundledTool {
  param([string]$SourceDir, [string]$FileName)
  $candidates = @(
    (Join-Path $SourceDir $FileName),
    (Join-Path (Join-Path $SourceDir "ffmpeg\bin") $FileName),
    (Join-Path (Join-Path $SourceDir "ffmpeg") $FileName)
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return ""
}

function Update-PanelShortcuts {
  param([string]$PanelPath, [string]$IconPath = "")
  if (-not (Test-Path -LiteralPath $PanelPath -PathType Leaf)) {
    return
  }
  $shortcutName = "Multivideo Playout.lnk"
  $commonDesktopShortcut = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) $shortcutName
  Set-Shortcut -ShortcutPath $commonDesktopShortcut -TargetPath $PanelPath -WorkingDirectory (Split-Path -Parent $PanelPath) -IconPath $IconPath
  Set-Shortcut -ShortcutPath (Join-Path ([Environment]::GetFolderPath("CommonPrograms")) "Multivideo\$shortcutName") -TargetPath $PanelPath -WorkingDirectory (Split-Path -Parent $PanelPath) -IconPath $IconPath
  Get-ChildItem -LiteralPath "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $desktopRoots = @(
      (Join-Path $_.FullName "Desktop"),
      (Join-Path $_.FullName "OneDrive\Desktop"),
      (Join-Path $_.FullName "OneDrive\Área de Trabalho"),
      (Join-Path $_.FullName "OneDrive\Area de Trabalho")
    )
    foreach ($desktopRoot in $desktopRoots) {
      $desktopShortcut = Join-Path $desktopRoot $shortcutName
      if (Test-Path -LiteralPath $desktopShortcut -PathType Leaf) {
        try {
          $shell = New-Object -ComObject WScript.Shell
          $existing = $shell.CreateShortcut($desktopShortcut)
          if ($existing.TargetPath -eq $PanelPath -and $desktopShortcut -ne $commonDesktopShortcut) {
            Remove-Item -LiteralPath $desktopShortcut -Force
          } else {
            Set-Shortcut -ShortcutPath $desktopShortcut -TargetPath $PanelPath -WorkingDirectory (Split-Path -Parent $PanelPath) -IconPath $IconPath
          }
        } catch {
          Set-Shortcut -ShortcutPath $desktopShortcut -TargetPath $PanelPath -WorkingDirectory (Split-Path -Parent $PanelPath) -IconPath $IconPath
        }
      }
    }
  }
  try {
    & "$env:WINDIR\System32\ie4uinit.exe" -show | Out-Null
  } catch {
    Write-Warning "Could not refresh Windows icon cache: $($_.Exception.Message)"
  }
}

if (-not $NoElevate -and -not (Test-IsAdmin)) {
  $args = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $PSCommandPath,
    "-InstallDir", $InstallDir,
    "-PlayoutHome", $PlayoutHome,
    "-Bind", $Bind,
    "-PublicBaseUrl", $PublicBaseUrl,
    "-ControlPlaneUrl", $ControlPlaneUrl,
    "-LicenseRequired", $LicenseRequired,
    "-FfmpegPath", $FfmpegPath,
    "-FfprobePath", $FfprobePath,
    "-TmdbApiKey", $TmdbApiKey,
    "-ReleaseId", $ReleaseId,
    "-ServiceName", $ServiceName,
    "-DisplayName", $DisplayName,
    "-Configuration", $Configuration,
    "-NoElevate"
  )
  if (-not [string]::IsNullOrWhiteSpace($SourceDir)) {
    $args += @("-SourceDir", $SourceDir)
  }
  if ($Build) {
    $args += "-Build"
  }
  if ($NoStart) {
    $args += "-NoStart"
  }

  Start-Process -FilePath "powershell.exe" -ArgumentList (Join-Args $args) -Verb RunAs
  Write-Host "Elevation requested. Confirm the UAC prompt to install the Playout runtime service."
  exit 0
}

if (-not (Test-IsAdmin)) {
  throw "Administrator permission is required to install a Windows service."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$profile = if ($Configuration -eq "Release") { "release" } else { "debug" }
if ([string]::IsNullOrWhiteSpace($SourceDir)) {
  $scriptDirHasBinaries = Test-Path -LiteralPath (Join-Path $PSScriptRoot "playout-service.exe") -PathType Leaf
  if ($scriptDirHasBinaries) {
    $SourceDir = $PSScriptRoot
  } else {
    $SourceDir = Join-Path $repoRoot "target\$profile"
  }
}

if ($Build) {
  if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "Cargo.toml") -PathType Leaf)) {
    throw "Cannot build from $repoRoot because Cargo.toml was not found. Run from the source tree or omit -Build when using a packaged runtime."
  }
  Push-Location $repoRoot
  try {
    if ($Configuration -eq "Release") {
      cargo build --workspace --release
    } else {
      cargo build --workspace
    }
  } finally {
    Pop-Location
  }
}

$required = @(
  "playout-service.exe",
  "playout-api.exe",
  "playout-runner.exe"
)

foreach ($file in $required) {
  $path = Join-Path $SourceDir $file
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing runtime binary: $path. Run with -Build or package first."
  }
}

New-Item -ItemType Directory -Force $InstallDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $PlayoutHome "data") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $PlayoutHome "runtime\channels") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $PlayoutHome "logs") | Out-Null

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Host "Stopping existing service $ServiceName..."
  if ($existing.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $existing.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
  }
  Invoke-Sc @("delete", $ServiceName)
  Start-Sleep -Seconds 2
}

foreach ($file in $required) {
  Copy-Item -LiteralPath (Join-Path $SourceDir $file) -Destination (Join-Path $InstallDir $file) -Force
}

$panelSource = Join-Path $SourceDir "multivideo-playout-panel.exe"
if (Test-Path -LiteralPath $panelSource -PathType Leaf) {
  Copy-Item -LiteralPath $panelSource -Destination (Join-Path $InstallDir "multivideo-playout-panel.exe") -Force
}

$iconSource = Join-Path $SourceDir "multivideo-playout.ico"
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) {
  $iconSource = Join-Path $repoRoot "app\panel-ui\src-tauri\icons\icon.ico"
}
if (Test-Path -LiteralPath $iconSource -PathType Leaf) {
  Copy-Item -LiteralPath $iconSource -Destination (Join-Path $InstallDir "multivideo-playout.ico") -Force
}

$updateScriptSource = Join-Path $SourceDir "apply-playout-update.ps1"
if (-not (Test-Path -LiteralPath $updateScriptSource -PathType Leaf)) {
  $updateScriptSource = Join-Path $PSScriptRoot "apply-playout-update.ps1"
}
if (-not (Test-Path -LiteralPath $updateScriptSource -PathType Leaf)) {
  throw "Missing update script: apply-playout-update.ps1"
}
Copy-Item -LiteralPath $updateScriptSource -Destination (Join-Path $InstallDir "apply-playout-update.ps1") -Force

$bundledFfmpegSource = Resolve-BundledTool -SourceDir $SourceDir -FileName "ffmpeg.exe"
$bundledFfprobeSource = Resolve-BundledTool -SourceDir $SourceDir -FileName "ffprobe.exe"
if (-not [string]::IsNullOrWhiteSpace($FfmpegPath) -and (Test-IsUnderPath -Path $FfmpegPath -Root $SourceDir)) {
  $bundledFfmpegSource = $FfmpegPath
}
if (-not [string]::IsNullOrWhiteSpace($FfprobePath) -and (Test-IsUnderPath -Path $FfprobePath -Root $SourceDir)) {
  $bundledFfprobeSource = $FfprobePath
}
if ($bundledFfmpegSource -and $bundledFfprobeSource -and
  (Test-Path -LiteralPath $bundledFfmpegSource -PathType Leaf) -and
  (Test-Path -LiteralPath $bundledFfprobeSource -PathType Leaf)) {
  $installedFfmpegDir = Join-Path $InstallDir "ffmpeg\bin"
  New-Item -ItemType Directory -Force -Path $installedFfmpegDir | Out-Null
  $installedFfmpegPath = Join-Path $installedFfmpegDir "ffmpeg.exe"
  $installedFfprobePath = Join-Path $installedFfmpegDir "ffprobe.exe"
  Copy-Item -LiteralPath $bundledFfmpegSource -Destination $installedFfmpegPath -Force
  Copy-Item -LiteralPath $bundledFfprobeSource -Destination $installedFfprobePath -Force
  if ([string]::IsNullOrWhiteSpace($FfmpegPath) -or (Test-IsUnderPath -Path $FfmpegPath -Root $SourceDir)) {
    $FfmpegPath = $installedFfmpegPath
  }
  if ([string]::IsNullOrWhiteSpace($FfprobePath) -or (Test-IsUnderPath -Path $FfprobePath -Root $SourceDir)) {
    $FfprobePath = $installedFfprobePath
  }
  $noticeSource = Join-Path $SourceDir "FFMPEG-NOTICE.txt"
  if (Test-Path -LiteralPath $noticeSource -PathType Leaf) {
    Copy-Item -LiteralPath $noticeSource -Destination (Join-Path $InstallDir "FFMPEG-NOTICE.txt") -Force
  }
}

$apiPath = Join-Path $InstallDir "playout-api.exe"
$runnerPath = Join-Path $InstallDir "playout-runner.exe"
$servicePath = Join-Path $InstallDir "playout-service.exe"
$envPath = Join-Path $InstallDir "playout-runtime.env"
$existingLicenseRequired = ""
if (Test-Path -LiteralPath $envPath -PathType Leaf) {
  $existingLicenseRequired = Get-Content -LiteralPath $envPath |
    Where-Object { $_ -match '^\s*PLAYOUT_LICENSE_REQUIRED\s*=' } |
    Select-Object -First 1
  if ($existingLicenseRequired -and $existingLicenseRequired -match '^\s*PLAYOUT_LICENSE_REQUIRED\s*=\s*(.+?)\s*$') {
    $existingLicenseRequired = $Matches[1].Trim().Trim('"')
  } else {
    $existingLicenseRequired = ""
  }
}
$effectiveLicenseRequired = if (-not [string]::IsNullOrWhiteSpace($LicenseRequired)) {
  Normalize-BoolSetting -Value $LicenseRequired
} elseif (-not [string]::IsNullOrWhiteSpace($existingLicenseRequired)) {
  Normalize-BoolSetting -Value $existingLicenseRequired
} else {
  "true"
}
if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
  $ffmpegCommand = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($ffmpegCommand) {
    $FfmpegPath = $ffmpegCommand.Source
  } elseif (Test-Path -LiteralPath "C:\ffmpeg\ffmpeg.exe" -PathType Leaf) {
    $FfmpegPath = "C:\ffmpeg\ffmpeg.exe"
  } else {
    $FfmpegPath = "ffmpeg"
  }
}
if ([string]::IsNullOrWhiteSpace($FfprobePath)) {
  $ffprobeCommand = Get-Command ffprobe -ErrorAction SilentlyContinue
  if ($ffprobeCommand) {
    $FfprobePath = $ffprobeCommand.Source
  } elseif (-not [string]::IsNullOrWhiteSpace($FfmpegPath)) {
    $candidate = Join-Path (Split-Path -Parent $FfmpegPath) "ffprobe.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $FfprobePath = $candidate
    }
  } elseif (Test-Path -LiteralPath "C:\ffmpeg\ffprobe.exe" -PathType Leaf) {
    $FfprobePath = "C:\ffmpeg\ffprobe.exe"
  } else {
    $FfprobePath = "ffprobe"
  }
}

$envContent = @"
PLAYOUT_HOME=$PlayoutHome
PLAYOUT_BIND=$Bind
PUBLIC_BASE_URL=$PublicBaseUrl
PLAYOUT_API_PATH=$apiPath
PLAYOUT_RUNNER_PATH=$runnerPath
FFMPEG_PATH=$FfmpegPath
FFPROBE_PATH=$FfprobePath
PLAYOUT_TMDB_API_KEY=$TmdbApiKey
PLAYOUT_RELEASE_ID=$ReleaseId
RUST_LOG=playout_api=info,tower_http=info
"@
$envContent = $envContent.TrimEnd("`r", "`n") + "`r`n"
if (-not [string]::IsNullOrWhiteSpace($ControlPlaneUrl)) {
  $envContent += "PLAYOUT_CONTROL_PLANE_URL=$($ControlPlaneUrl.TrimEnd('/'))`r`n"
}
$envContent += "PLAYOUT_LICENSE_REQUIRED=$effectiveLicenseRequired`r`n"
$envContent | Set-Content -LiteralPath $envPath -Encoding UTF8

$binPath = "`"$servicePath`" run-service"
New-Service `
  -Name $ServiceName `
  -BinaryPathName $binPath `
  -DisplayName $DisplayName `
  -StartupType Automatic | Out-Null
Invoke-Sc @("description", $ServiceName, "Keeps the Multivideo Playout local API and channel runner runtime online.")
Invoke-Sc @("failure", $ServiceName, "reset=", "60", "actions=", "restart/5000/restart/5000/restart/30000")

if (-not $NoStart) {
  Start-Service -Name $ServiceName
  (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
}

Update-PanelShortcuts -PanelPath (Join-Path $InstallDir "multivideo-playout-panel.exe") -IconPath (Join-Path $InstallDir "multivideo-playout.ico")

Write-Host "Installed $ServiceName"
Write-Host "InstallDir: $InstallDir"
Write-Host "PlayoutHome: $PlayoutHome"
Write-Host "Config: $envPath"
