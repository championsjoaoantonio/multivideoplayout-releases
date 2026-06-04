param(
  [string]$InstallDir = "C:\Program Files\Multivideo\Playout",
  [string]$PlayoutHome = "C:\ProgramData\Multivideo\Playout",
  [string]$ServiceName = "MultivideoPlayoutRuntime",
  [string]$ManifestUrl = "",
  [string]$PackageUrl = "",
  [string]$PackageSha256 = "",
  [string]$TargetReleaseId = "",
  [string]$TargetVersion = "",
  [string]$StatusFile = "",
  [string]$LogFile = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($TargetReleaseId)) {
  $TargetReleaseId = "manual-" + (Get-Date -Format "yyyyMMddHHmmss")
}
if ([string]::IsNullOrWhiteSpace($TargetVersion)) {
  $TargetVersion = "unknown"
}
if ([string]::IsNullOrWhiteSpace($StatusFile)) {
  $StatusFile = Join-Path $PlayoutHome "updates\state\update-state.json"
}
if ([string]::IsNullOrWhiteSpace($LogFile)) {
  $LogFile = Join-Path $PlayoutHome "updates\logs\update.log"
}

$updateRoot = Join-Path $PlayoutHome "updates"
$stateDir = Join-Path $updateRoot "state"
$stageRoot = Join-Path $updateRoot "staging"
$backupRoot = Join-Path $updateRoot "backups"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stageDir = Join-Path $stageRoot "$stamp-$TargetReleaseId"
$backupDir = Join-Path $backupRoot "$stamp-$TargetReleaseId"
$resumeChannelsPath = Join-Path $stageDir "resume-channels.json"
$script:PanelUpdateDeferred = $false

function Ensure-Dirs {
  New-Item -ItemType Directory -Force -Path $stateDir, (Split-Path -Parent $LogFile), $stageDir, $backupDir | Out-Null
}

function Write-UpdateLog {
  param([string]$Message)
  Ensure-Dirs
  $line = "[{0}] {1}" -f (Get-Date -Format "o"), $Message
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Write-UpdateState {
  param(
    [string]$Status,
    [string]$Message,
    [string]$FinishedAt = ""
  )
  Ensure-Dirs
  $payload = [ordered]@{
    schema_version = "multivideo.playout.update-state.v1"
    product_code = "PLAYOUT"
    status = $Status
    release_id = $TargetReleaseId
    target_version = $TargetVersion
    manifest_url = $(if ([string]::IsNullOrWhiteSpace($ManifestUrl)) { $null } else { $ManifestUrl })
    package_url = $(if ([string]::IsNullOrWhiteSpace($PackageUrl)) { $null } else { $PackageUrl })
    package_sha256 = $(if ([string]::IsNullOrWhiteSpace($PackageSha256)) { $null } else { $PackageSha256.ToLowerInvariant() })
    started_at = $script:StartedAt
    finished_at = $(if ([string]::IsNullOrWhiteSpace($FinishedAt)) { $null } else { $FinishedAt })
    message = $Message
    log_path = $LogFile
    backup_dir = $backupDir
    stage_dir = $stageDir
    log_tail = @()
  }
  $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatusFile -Encoding UTF8
}

function Get-CurrentRelease {
  $path = Join-Path $stateDir "current-release.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $null
  }
  try {
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  } catch {
    Write-UpdateLog "Could not read current release file: $($_.Exception.Message)"
    return $null
  }
}

function Test-ReleaseAlreadyInstalled {
  if ([string]::IsNullOrWhiteSpace($TargetReleaseId)) {
    return $false
  }
  $current = Get-CurrentRelease
  if (-not $current -or [string]$current.release_id -ne $TargetReleaseId) {
    return $false
  }
  if (-not [string]::IsNullOrWhiteSpace($PackageSha256) -and -not [string]::IsNullOrWhiteSpace([string]$current.package_sha256)) {
    return ([string]$current.package_sha256).Trim().ToLowerInvariant() -eq $PackageSha256.Trim().ToLowerInvariant()
  }
  return $true
}

function Resolve-PackageUrlFromManifest {
  param([object]$Manifest, [string]$SourceUrl)
  if ($Manifest.package_url) { return [string]$Manifest.package_url }
  if ($Manifest.package -and $Manifest.package.url) { return [string]$Manifest.package.url }
  if ($Manifest.archive -and $Manifest.archive.url) { return [string]$Manifest.archive.url }
  if ($Manifest.archive -and $Manifest.archive.file) {
    return ([Uri]::new([Uri]$SourceUrl, [string]$Manifest.archive.file)).AbsoluteUri
  }
  return ""
}

function Resolve-PackageShaFromManifest {
  param([object]$Manifest)
  if ($Manifest.package_sha256) { return [string]$Manifest.package_sha256 }
  if ($Manifest.package -and $Manifest.package.sha256) { return [string]$Manifest.package.sha256 }
  if ($Manifest.archive -and $Manifest.archive.sha256) { return [string]$Manifest.archive.sha256 }
  return ""
}

function Resolve-PayloadRoot {
  param([string]$ExtractDir)
  $direct = Join-Path $ExtractDir "playout-api.exe"
  if (Test-Path -LiteralPath $direct -PathType Leaf) {
    return $ExtractDir
  }
  $candidate = Get-ChildItem -LiteralPath $ExtractDir -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "playout-api.exe") -PathType Leaf } |
    Select-Object -First 1
  if ($candidate) {
    return $candidate.FullName
  }
  throw "Package does not contain playout-api.exe at the expected root."
}

function Get-ApiBaseUrl {
  $envPath = Join-Path $InstallDir "playout-runtime.env"
  $bind = "127.0.0.1:8091"
  if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    $line = Get-Content -LiteralPath $envPath |
      Where-Object { $_ -match '^\s*PLAYOUT_BIND\s*=' } |
      Select-Object -First 1
    if ($line -and $line -match '^\s*PLAYOUT_BIND\s*=\s*(.+?)\s*$') {
      $bind = $Matches[1].Trim().Trim('"')
    }
  }
  if ($bind -match '^https?://') {
    return $bind.TrimEnd("/")
  }
  if ($bind -match '^(0\.0\.0\.0|\[::\]|::):(.+)$') {
    $bind = "127.0.0.1:$($Matches[2])"
  }
  return "http://$bind"
}

function Save-RunningChannelsForResume {
  $apiBaseUrl = Get-ApiBaseUrl
  try {
    $channels = Invoke-RestMethod -Uri "$apiBaseUrl/api/local/v1/channels" -UseBasicParsing -TimeoutSec 8
    $running = @($channels | Where-Object { $_.enabled } | ForEach-Object {
      $channel = $_
      try {
        $status = Invoke-RestMethod -Uri "$apiBaseUrl/api/local/v1/channels/$($channel.channel_id)/status" -UseBasicParsing -TimeoutSec 5
        if ($status.state -in @("starting", "running")) {
          $now = $status.now
          [ordered]@{
            channel_id = [string]$channel.channel_id
            slug = [string]$channel.slug
            name = [string]$channel.name
            state = [string]$status.state
            remote_state = if ($status.remote_state) { [string]$status.remote_state } else { $null }
            current_title = if ($now -and $now.title) { [string]$now.title } else { $null }
            current_source = if ($now -and $now.path) { [string]$now.path } else { $null }
            current_position = if ($now -and $null -ne $now.position) { [int]$now.position } else { $null }
            elapsed_seconds = if ($now -and $null -ne $now.elapsed_seconds) { [int64]$now.elapsed_seconds } else { $null }
            source_elapsed_seconds = if ($now -and $null -ne $now.source_elapsed_seconds) { [int64]$now.source_elapsed_seconds } else { $null }
            duration_seconds = if ($now -and $null -ne $now.duration_seconds) { [int]$now.duration_seconds } else { $null }
          }
        }
      } catch {
        Write-UpdateLog "Could not inspect channel $($channel.name) ($($channel.channel_id)) for resume: $($_.Exception.Message)"
      }
    })
    $payload = [ordered]@{
      captured_at = Get-Date -Format "o"
      api_base_url = $apiBaseUrl
      channels = $running
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resumeChannelsPath -Encoding UTF8
    Write-UpdateLog "Captured $($running.Count) running channel(s) for resume"
  } catch {
    $payload = [ordered]@{
      captured_at = Get-Date -Format "o"
      api_base_url = $apiBaseUrl
      channels = @()
      error = $_.Exception.Message
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resumeChannelsPath -Encoding UTF8
    Write-UpdateLog "Could not capture running channels for resume: $($_.Exception.Message)"
  }
}

function Wait-LocalApi {
  param([string]$ApiBaseUrl)
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $health = Invoke-RestMethod -Uri "$ApiBaseUrl/api/local/v1/health" -UseBasicParsing -TimeoutSec 3
      if ($health.status -eq "ok") {
        return $true
      }
    } catch {}
    Start-Sleep -Seconds 2
  }
  return $false
}

function Resume-RunningChannels {
  if (-not (Test-Path -LiteralPath $resumeChannelsPath -PathType Leaf)) {
    Write-UpdateLog "No running channel resume file found"
    return
  }
  try {
    $resume = Get-Content -LiteralPath $resumeChannelsPath -Raw | ConvertFrom-Json
    $channels = @($resume.channels)
    if ($channels.Count -eq 0) {
      Write-UpdateLog "No channels were running before update"
      return
    }
    $apiBaseUrl = if ($resume.api_base_url) { [string]$resume.api_base_url } else { Get-ApiBaseUrl }
    $capturedAt = $null
    try {
      if ($resume.captured_at) {
        $capturedAt = [DateTimeOffset]::Parse([string]$resume.captured_at)
      }
    } catch {
      Write-UpdateLog "Could not parse resume captured_at '$($resume.captured_at)': $($_.Exception.Message)"
    }
    if (-not (Wait-LocalApi -ApiBaseUrl $apiBaseUrl)) {
      Write-UpdateLog "Local API did not become healthy; skipped channel resume"
      return
    }
    $resumed = 0
    foreach ($channel in $channels) {
      try {
        $channelId = [string]$channel.channel_id
        $body = [ordered]@{}
        $resumeElapsed = if ($null -ne $channel.source_elapsed_seconds) { $channel.source_elapsed_seconds } else { $channel.elapsed_seconds }
        if ($channel.current_source -and $null -ne $resumeElapsed) {
          $elapsed = [int64]$resumeElapsed
          if ($capturedAt) {
            $elapsed += [int64]([DateTimeOffset]::Now - $capturedAt).TotalSeconds
          }
          $body.resume_source = [string]$channel.current_source
          $body.resume_elapsed_seconds = [Math]::Max([int64]0, [int64]$elapsed)
          if ($null -ne $channel.current_position) {
            $body.resume_position = [int]$channel.current_position
          }
          Write-UpdateLog "Resume point for channel $($channel.name) ($channelId): $($channel.current_title) at $($body.resume_elapsed_seconds)s"
        }
        $jsonBody = $body | ConvertTo-Json -Depth 4
        if ([string]::IsNullOrWhiteSpace($jsonBody)) {
          $jsonBody = "{}"
        }
        Invoke-RestMethod -Method Post -Uri "$apiBaseUrl/api/local/v1/channels/$channelId/start" -ContentType "application/json" -Body $jsonBody -UseBasicParsing -TimeoutSec 10 | Out-Null
        $resumed++
        Write-UpdateLog "Resume requested for channel $($channel.name) ($channelId)"
      } catch {
        Write-UpdateLog "Could not resume channel $($channel.name) ($($channel.channel_id)): $($_.Exception.Message)"
      }
    }
    Write-UpdateLog "Resume requested for $resumed/$($channels.Count) channel(s)"
  } catch {
    Write-UpdateLog "Channel resume failed: $($_.Exception.Message)"
  }
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
    Write-UpdateLog "Could not update shortcut ${ShortcutPath}: $($_.Exception.Message)"
  }
}

function Update-PanelShortcuts {
  param([string]$PanelPath, [string]$IconPath = "")
  if (-not (Test-Path -LiteralPath $PanelPath -PathType Leaf)) {
    Write-UpdateLog "Panel executable not found for shortcut update: $PanelPath"
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
    Write-UpdateLog "Could not refresh Windows icon cache: $($_.Exception.Message)"
  }
  Write-UpdateLog "Panel shortcuts updated: $PanelPath"
}

function Copy-PayloadFile {
  param(
    [string]$Source,
    [string]$Destination,
    [bool]$OptionalWhenLocked = $false
  )
  try {
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $true
  } catch {
    $message = $_.Exception.Message
    if ($OptionalWhenLocked -and $message -match "being used by another process|sendo usado por outro processo|não pode acessar o arquivo|cannot access the file") {
      Write-UpdateLog "Skipped locked panel file during update: $Destination"
      $script:PanelUpdateDeferred = $true
      return $false
    }
    throw
  }
}

function Copy-Payload {
  param([string]$PayloadRoot)
  $required = @("playout-service.exe", "playout-api.exe", "playout-runner.exe", "apply-playout-update.ps1")
  foreach ($file in $required) {
    $path = Join-Path $PayloadRoot $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Missing required package file: $file"
    }
  }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $envBackup = $null
  $envPath = Join-Path $InstallDir "playout-runtime.env"
  if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    $envBackup = Join-Path $stageDir "playout-runtime.env.current"
    Copy-Item -LiteralPath $envPath -Destination $envBackup -Force
  }

  Get-ChildItem -LiteralPath $PayloadRoot -File | ForEach-Object {
    if ($_.Name -ne "playout-runtime.env") {
      $destination = Join-Path $InstallDir $_.Name
      $optionalPanel = $_.Name -eq "multivideo-playout-panel.exe"
      Copy-PayloadFile -Source $_.FullName -Destination $destination -OptionalWhenLocked $optionalPanel | Out-Null
    }
  }

  if ($envBackup -and (Test-Path -LiteralPath $envBackup -PathType Leaf)) {
    Copy-Item -LiteralPath $envBackup -Destination $envPath -Force
  }
  Update-PanelShortcuts -PanelPath (Join-Path $InstallDir "multivideo-playout-panel.exe") -IconPath (Join-Path $InstallDir "multivideo-playout.ico")
}

function Stop-PlayoutService {
  $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($service -and $service.Status -ne "Stopped") {
    Write-UpdateLog "Stopping service $ServiceName"
    Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
    (Get-Service -Name $ServiceName).WaitForStatus("Stopped", [TimeSpan]::FromSeconds(45))
  }
}

function Start-PlayoutService {
  $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($service) {
    Write-UpdateLog "Starting service $ServiceName"
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(45))
  }
}

$script:StartedAt = Get-Date -Format "o"

try {
  Ensure-Dirs
  if (Test-ReleaseAlreadyInstalled) {
    Write-UpdateLog "Update $TargetReleaseId already installed; skipping"
    Write-UpdateState -Status "succeeded" -Message "Release already installed; skipping update." -FinishedAt (Get-Date -Format "o")
    exit 0
  }
  Write-UpdateLog "Starting Playout update $TargetReleaseId"
  Write-UpdateState -Status "downloading" -Message "Downloading update artifacts."

  $manifestPath = Join-Path $stageDir "release.json"
  if (-not [string]::IsNullOrWhiteSpace($ManifestUrl)) {
    Write-UpdateLog "Downloading manifest: $ManifestUrl"
    Invoke-WebRequest -Uri $ManifestUrl -OutFile $manifestPath -UseBasicParsing
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.product_code -and [string]$manifest.product_code -ne "PLAYOUT") {
      throw "Manifest product_code is not PLAYOUT."
    }
    if ([string]::IsNullOrWhiteSpace($PackageUrl)) {
      $PackageUrl = Resolve-PackageUrlFromManifest -Manifest $manifest -SourceUrl $ManifestUrl
    }
    if ([string]::IsNullOrWhiteSpace($PackageSha256)) {
      $PackageSha256 = Resolve-PackageShaFromManifest -Manifest $manifest
    }
  }

  if ([string]::IsNullOrWhiteSpace($PackageUrl)) {
    throw "Package URL not found in update response or manifest."
  }
  if ([string]::IsNullOrWhiteSpace($PackageSha256)) {
    throw "Package SHA256 not found in update response or manifest."
  }

  $packagePath = Join-Path $stageDir "package.zip"
  Write-UpdateLog "Downloading package: $PackageUrl"
  Invoke-WebRequest -Uri $PackageUrl -OutFile $packagePath -UseBasicParsing

  Write-UpdateState -Status "validating" -Message "Validating package SHA256."
  $actualSha = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedSha = $PackageSha256.Trim().ToLowerInvariant()
  if ($actualSha -ne $expectedSha) {
    throw "Package SHA256 mismatch. Expected $expectedSha but got $actualSha."
  }

  Write-UpdateState -Status "applying" -Message "Applying update with local rollback."
  $extractDir = Join-Path $stageDir "payload"
  Expand-Archive -LiteralPath $packagePath -DestinationPath $extractDir -Force
  $payloadRoot = Resolve-PayloadRoot -ExtractDir $extractDir

  if (Test-Path -LiteralPath $InstallDir) {
    Write-UpdateLog "Creating backup: $backupDir"
    Get-ChildItem -LiteralPath $InstallDir -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $backupDir -Recurse -Force
    }
  }

  Save-RunningChannelsForResume
  Stop-PlayoutService
  Copy-Payload -PayloadRoot $payloadRoot
  Start-PlayoutService
  Resume-RunningChannels

  $currentRelease = [ordered]@{
    product_code = "PLAYOUT"
    release_id = $TargetReleaseId
    version = $TargetVersion
    applied_at = Get-Date -Format "o"
    manifest_url = $(if ([string]::IsNullOrWhiteSpace($ManifestUrl)) { $null } else { $ManifestUrl })
    package_url = $PackageUrl
    package_sha256 = $expectedSha
  }
  $currentRelease | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stateDir "current-release.json") -Encoding UTF8
  if ($script:PanelUpdateDeferred) {
    Write-UpdateLog "Update $TargetReleaseId applied with panel replacement deferred because the panel was open"
    Write-UpdateState -Status "succeeded" -Message "Update applied to runtime. Panel executable was open and will be updated by the next installer/update run after closing the panel." -FinishedAt (Get-Date -Format "o")
  } else {
    Write-UpdateLog "Update $TargetReleaseId applied successfully"
    Write-UpdateState -Status "succeeded" -Message "Update applied successfully." -FinishedAt (Get-Date -Format "o")
  }
  exit 0
} catch {
  $message = $_.Exception.Message
  Write-UpdateLog "Update failed: $message"
  try {
    Write-UpdateState -Status "rollback_running" -Message "Update failed. Rolling back: $message"
    Stop-PlayoutService
    if (Test-Path -LiteralPath $backupDir) {
      New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
      Get-ChildItem -LiteralPath $backupDir -Force | ForEach-Object {
        $backupItem = $_
        try {
          Copy-Item -LiteralPath $backupItem.FullName -Destination $InstallDir -Recurse -Force
        } catch {
          $rollbackCopyMessage = $_.Exception.Message
          if ($backupItem.Name -eq "multivideo-playout-panel.exe" -and $rollbackCopyMessage -match "being used by another process|sendo usado por outro processo|não pode acessar o arquivo|cannot access the file") {
            Write-UpdateLog "Skipped locked panel file during rollback: $($backupItem.FullName)"
          } else {
            throw
          }
        }
      }
    }
    Start-PlayoutService
    Write-UpdateLog "Rollback completed"
    Write-UpdateState -Status "rollback_succeeded" -Message "Update failed and rollback completed: $message" -FinishedAt (Get-Date -Format "o")
  } catch {
    $rollbackMessage = $_.Exception.Message
    Write-UpdateLog "Rollback failed: $rollbackMessage"
    try {
      Start-PlayoutService
    } catch {
      Write-UpdateLog "Could not restart service after rollback failure: $($_.Exception.Message)"
    }
    Write-UpdateState -Status "rollback_failed" -Message "Update failed: $message. Rollback failed: $rollbackMessage" -FinishedAt (Get-Date -Format "o")
  }
  exit 1
}
