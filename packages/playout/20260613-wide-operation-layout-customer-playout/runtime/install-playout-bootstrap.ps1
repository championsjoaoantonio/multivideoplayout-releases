param(
  [string]$ReleaseId = "",
  [string]$InstallDir = "C:\Program Files\Multivideo\Playout",
  [string]$PlayoutHome = "C:\ProgramData\Multivideo\Playout",
  [string]$Bind = "0.0.0.0:8091",
  [string]$PublicBaseUrl = "",
  [string]$ControlPlaneUrl = "https://license.vorbio.me",
  [string]$LicenseRequired = "true",
  [string]$FfmpegPath = "",
  [string]$FfprobePath = "",
  [string]$TmdbApiKey = "",
  [switch]$SkipFirewall,
  [switch]$NoOpenPanel,
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

function Get-PrimaryIpv4 {
  try {
    $candidate = Get-NetIPConfiguration -ErrorAction Stop |
      Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq "Up" } |
      ForEach-Object { $_.IPv4Address | Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } } |
      Select-Object -First 1
    if ($candidate) {
      return $candidate.IPAddress
    }
  } catch {}

  try {
    $candidate = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
      ForEach-Object { $_.IPAddress } |
      Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike "169.254.*" -and $_ -ne "127.0.0.1" } |
      Select-Object -First 1
    if ($candidate) {
      return $candidate
    }
  } catch {}

  return "127.0.0.1"
}

function Resolve-ToolPath {
  param(
    [string]$ConfiguredPath,
    [string]$ToolName,
    [string[]]$Candidates
  )

  if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath) -and (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf)) {
    return $ConfiguredPath
  }

  $command = Get-Command $ToolName -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  foreach ($candidate in $Candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  return ""
}

function Get-PortFromBind {
  param([string]$Value)
  if ($Value -match ':(\d+)$') {
    return [int]$Matches[1]
  }
  return 8091
}

if (-not $NoElevate -and -not (Test-IsAdmin)) {
  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $PSCommandPath,
    "-ReleaseId", $ReleaseId,
    "-InstallDir", $InstallDir,
    "-PlayoutHome", $PlayoutHome,
    "-Bind", $Bind,
    "-PublicBaseUrl", $PublicBaseUrl,
    "-ControlPlaneUrl", $ControlPlaneUrl,
    "-LicenseRequired", $LicenseRequired,
    "-FfmpegPath", $FfmpegPath,
    "-FfprobePath", $FfprobePath,
    "-TmdbApiKey", $TmdbApiKey,
    "-NoElevate"
  )
  if ($SkipFirewall) {
    $args += "-SkipFirewall"
  }
  if ($NoOpenPanel) {
    $args += "-NoOpenPanel"
  }

  $process = Start-Process -FilePath "powershell.exe" -ArgumentList (Join-Args $args) -Verb RunAs -Wait -PassThru
  exit $process.ExitCode
}

if (-not (Test-IsAdmin)) {
  throw "Administrator permission is required to install Multivideo Playout."
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$installScript = Join-Path $scriptRoot "install-playout-runtime-service.ps1"
if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
  throw "Missing install-playout-runtime-service.ps1 next to bootstrap script."
}

$detectedIp = Get-PrimaryIpv4
if ([string]::IsNullOrWhiteSpace($PublicBaseUrl)) {
  $PublicBaseUrl = "http://$detectedIp`:$(Get-PortFromBind $Bind)"
}

$resolvedFfmpeg = Resolve-ToolPath `
  -ConfiguredPath $FfmpegPath `
  -ToolName "ffmpeg" `
  -Candidates @(
    (Join-Path $scriptRoot "ffmpeg.exe"),
    (Join-Path (Join-Path $scriptRoot "ffmpeg\bin") "ffmpeg.exe"),
    "C:\ffmpeg\bin\ffmpeg.exe",
    "C:\ffmpeg\ffmpeg.exe"
  )

$ffprobeCandidates = @(
  (Join-Path $scriptRoot "ffprobe.exe"),
  (Join-Path (Join-Path $scriptRoot "ffmpeg\bin") "ffprobe.exe"),
  "C:\ffmpeg\bin\ffprobe.exe",
  "C:\ffmpeg\ffprobe.exe"
)
if (-not [string]::IsNullOrWhiteSpace($resolvedFfmpeg)) {
  $ffprobeCandidates = @((Join-Path (Split-Path -Parent $resolvedFfmpeg) "ffprobe.exe")) + $ffprobeCandidates
}
$resolvedFfprobe = Resolve-ToolPath `
  -ConfiguredPath $FfprobePath `
  -ToolName "ffprobe" `
  -Candidates $ffprobeCandidates

$installArgs = @(
  "-InstallDir", $InstallDir,
  "-PlayoutHome", $PlayoutHome,
  "-Bind", $Bind,
  "-PublicBaseUrl", $PublicBaseUrl,
  "-ControlPlaneUrl", $ControlPlaneUrl,
  "-LicenseRequired", $LicenseRequired,
  "-ReleaseId", $ReleaseId,
  "-SourceDir", $scriptRoot,
  "-NoElevate"
)
if (-not [string]::IsNullOrWhiteSpace($resolvedFfmpeg)) {
  $installArgs += @("-FfmpegPath", $resolvedFfmpeg)
}
if (-not [string]::IsNullOrWhiteSpace($resolvedFfprobe)) {
  $installArgs += @("-FfprobePath", $resolvedFfprobe)
}
if (-not [string]::IsNullOrWhiteSpace($TmdbApiKey)) {
  $installArgs += @("-TmdbApiKey", $TmdbApiKey)
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript @installArgs
if ($LASTEXITCODE -ne 0) {
  throw "Runtime service installer failed with exit code $LASTEXITCODE."
}

$firewallMessage = "not changed"
if (-not $SkipFirewall) {
  $port = Get-PortFromBind $Bind
  $ruleName = "Multivideo Playout $port"
  $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
  if (-not $existingRule) {
    New-NetFirewallRule `
      -DisplayName $ruleName `
      -Direction Inbound `
      -Action Allow `
      -Protocol TCP `
      -LocalPort $port | Out-Null
    $firewallMessage = "created inbound TCP $port"
  } else {
    $firewallMessage = "already exists for TCP $port"
  }
}

$webView2Path = Get-ChildItem -Path @(
    "$env:ProgramFiles\Microsoft\EdgeWebView\Application",
    "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application"
  ) -Filter "msedgewebview2.exe" -Recurse -ErrorAction SilentlyContinue |
  Select-Object -First 1

$reportDir = Join-Path $PlayoutHome "logs"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$reportPath = Join-Path $reportDir "install-report.txt"
$report = @(
  "Multivideo Playout install report",
  "Installed at: $(Get-Date -Format o)",
  "Release: $ReleaseId",
  "InstallDir: $InstallDir",
  "PlayoutHome: $PlayoutHome",
  "Bind: $Bind",
  "PublicBaseUrl: $PublicBaseUrl",
  "ControlPlaneUrl: $ControlPlaneUrl",
  "LicenseRequired: $LicenseRequired",
  "FFmpeg: $(if ($resolvedFfmpeg) { $resolvedFfmpeg } else { 'NOT FOUND - install FFmpeg before starting channels' })",
  "FFprobe: $(if ($resolvedFfprobe) { $resolvedFfprobe } else { 'NOT FOUND - install FFprobe before starting channels' })",
  "WebView2: $(if ($webView2Path) { $webView2Path.FullName } else { 'NOT FOUND - install Microsoft Edge WebView2 Runtime if panel does not open' })",
  "Firewall: $firewallMessage",
  "OTT delivery: Playout publishes to the configured OTT ingest; subscriber delivery is handled by the OTT platform."
)
$report | Set-Content -LiteralPath $reportPath -Encoding UTF8

$panelPath = Join-Path $InstallDir "multivideo-playout-panel.exe"
if (-not $NoOpenPanel -and (Test-Path -LiteralPath $panelPath -PathType Leaf)) {
  Start-Process -FilePath $panelPath -WorkingDirectory $InstallDir | Out-Null
}

Write-Host "Multivideo Playout installed."
Write-Host "Panel: $panelPath"
Write-Host "API: http://127.0.0.1:8091"
Write-Host "Public base URL: $PublicBaseUrl"
Write-Host "Control-plane URL: $ControlPlaneUrl"
Write-Host "License required: $LicenseRequired"
Write-Host "Install report: $reportPath"
if (-not $resolvedFfmpeg -or -not $resolvedFfprobe) {
  Write-Warning "FFmpeg/FFprobe were not found. Install them before starting channels."
}
if (-not $webView2Path) {
  Write-Warning "WebView2 Runtime was not detected. Install it if the panel does not open."
}
