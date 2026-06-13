param(
  [string]$ServiceName = "MultivideoPlayoutRuntime",
  [string]$InstallDir = "C:\Program Files\Multivideo\Playout",
  [switch]$RemoveInstallDir,
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

if (-not $NoElevate -and -not (Test-IsAdmin)) {
  $args = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $PSCommandPath,
    "-ServiceName", $ServiceName,
    "-InstallDir", $InstallDir,
    "-NoElevate"
  )
  if ($RemoveInstallDir) {
    $args += "-RemoveInstallDir"
  }

  Start-Process -FilePath "powershell.exe" -ArgumentList (Join-Args $args) -Verb RunAs
  Write-Host "Elevation requested. Confirm the UAC prompt to uninstall the Playout runtime service."
  exit 0
}

if (-not (Test-IsAdmin)) {
  throw "Administrator permission is required to remove a Windows service."
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
  if ($existing.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $existing.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
  }
  Invoke-Sc @("delete", $ServiceName)
  Start-Sleep -Seconds 2
  Write-Host "Removed service $ServiceName"
} else {
  Write-Host "Service $ServiceName was not installed."
}

if ($RemoveInstallDir -and (Test-Path -LiteralPath $InstallDir)) {
  $resolved = Resolve-Path -LiteralPath $InstallDir
  if ($resolved.Path -ieq "C:\" -or $resolved.Path.Length -lt 10) {
    throw "Refusing to remove suspicious install directory: $($resolved.Path)"
  }
  Remove-Item -LiteralPath $resolved.Path -Recurse -Force
  Write-Host "Removed install directory $($resolved.Path)"
}

Write-Host "Runtime data under C:\ProgramData\Multivideo\Playout was not removed."
