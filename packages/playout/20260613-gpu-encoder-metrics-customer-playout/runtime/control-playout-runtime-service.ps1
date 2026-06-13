param(
  [ValidateSet("status", "start", "stop", "restart")]
  [string]$Action = "status",

  [string]$ServiceName = "MultivideoPlayoutRuntime",
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

if ($Action -ne "status" -and -not $NoElevate -and -not (Test-IsAdmin)) {
  $args = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $PSCommandPath,
    "-Action", $Action,
    "-ServiceName", $ServiceName,
    "-NoElevate"
  )
  Start-Process -FilePath "powershell.exe" -ArgumentList (Join-Args $args) -Verb RunAs
  Write-Host "Elevation requested. Confirm the UAC prompt to control the Playout runtime service."
  exit 0
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
  throw "Service not found: $ServiceName"
}

switch ($Action) {
  "status" {
    $cim = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    [pscustomobject]@{
      Name = $service.Name
      DisplayName = $service.DisplayName
      Status = $service.Status.ToString()
      StartMode = $cim.StartMode
      PathName = $cim.PathName
    } | Format-List
  }
  "start" {
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    Get-Service -Name $ServiceName
  }
  "stop" {
    Stop-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
    Get-Service -Name $ServiceName
  }
  "restart" {
    Restart-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    Get-Service -Name $ServiceName
  }
}
