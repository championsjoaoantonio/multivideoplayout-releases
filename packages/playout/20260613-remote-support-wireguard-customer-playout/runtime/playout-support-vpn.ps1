param(
  [ValidateSet("status", "connect", "disconnect", "ensure-service")]
  [string]$Action = "status",
  [string]$InstallDir = "C:\Program Files\Multivideo\Playout",
  [string]$PlayoutHome = "C:\ProgramData\Multivideo\Playout",
  [string]$LoginServer = "vpn.vorbio.me",
  [string]$Hostname = "",
  [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

$supportRoot = Join-Path $PlayoutHome "support-vpn"
$logDir = Join-Path $supportRoot "logs"
$bundledDir = Join-Path $InstallDir "support-vpn"
$tunnelPrefix = "multivideo"

function New-Result {
  param(
    [string]$Status,
    [bool]$Installed,
    [bool]$Connected,
    [string]$Message,
    [string]$VpnIp = "",
    [string]$HostnameValue = "",
    [string]$LastError = ""
  )
  [ordered]@{
    schema_version = "multivideo.playout.support-vpn.v1"
    driver = "wireguard"
    status = $Status
    installed = $Installed
    connected = $Connected
    login_server = $LoginServer
    hostname = if ([string]::IsNullOrWhiteSpace($HostnameValue)) { $null } else { $HostnameValue }
    vpn_ip = if ([string]::IsNullOrWhiteSpace($VpnIp)) { $null } else { $VpnIp }
    tailnet_ip = if ([string]::IsNullOrWhiteSpace($VpnIp)) { $null } else { $VpnIp }
    message = $Message
    last_error = if ([string]::IsNullOrWhiteSpace($LastError)) { $null } else { $LastError }
  }
}

function Write-JsonResult {
  param([object]$Value)
  $Value | ConvertTo-Json -Depth 8 -Compress
}

function Find-WireGuardExe {
  $candidates = @(
    (Join-Path $env:ProgramFiles "WireGuard\wireguard.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "WireGuard\wireguard.exe"),
    (Join-Path $bundledDir "bin\wireguard.exe")
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return ""
}

function Find-WireGuardMsi {
  $candidates = @(
    (Join-Path $bundledDir "wireguard-amd64.msi"),
    (Join-Path $bundledDir "wireguard.msi"),
    (Join-Path $supportRoot "wireguard-amd64.msi")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  $wildcard = Get-ChildItem -LiteralPath $bundledDir -Filter "wireguard*.msi" -File -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($wildcard) {
    return $wildcard.FullName
  }
  return ""
}

function Ensure-WireGuardInstalled {
  $wireguard = Find-WireGuardExe
  if (-not [string]::IsNullOrWhiteSpace($wireguard)) {
    return $wireguard
  }

  $msi = Find-WireGuardMsi
  if ([string]::IsNullOrWhiteSpace($msi)) {
    throw "WireGuard nao esta instalado e o instalador offline nao foi encontrado."
  }

  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $logPath = Join-Path $logDir "wireguard-msi.log"
  $process = Start-Process -FilePath "msiexec.exe" `
    -ArgumentList @("/i", "`"$msi`"", "/qn", "/norestart", "/L*v", "`"$logPath`"") `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
  if ($process.ExitCode -ne 0) {
    throw "Falha ao instalar WireGuard offline. Codigo $($process.ExitCode)."
  }

  $wireguard = Find-WireGuardExe
  if ([string]::IsNullOrWhiteSpace($wireguard)) {
    throw "WireGuard foi instalado, mas o executavel nao foi localizado."
  }
  return $wireguard
}

function Find-Config {
  if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return $ConfigPath
  }
  if (-not [string]::IsNullOrWhiteSpace($env:PLAYOUT_SUPPORT_VPN_CONFIG) -and
    (Test-Path -LiteralPath $env:PLAYOUT_SUPPORT_VPN_CONFIG -PathType Leaf)) {
    return $env:PLAYOUT_SUPPORT_VPN_CONFIG
  }

  $preferred = @(
    (Join-Path $supportRoot "multivideo-support.conf"),
    (Join-Path $supportRoot "multivideo-bench.conf"),
    (Join-Path $bundledDir "multivideo-support.conf")
  )
  foreach ($candidate in $preferred) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  $config = Get-ChildItem -LiteralPath $supportRoot -Filter "$tunnelPrefix*.conf" -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    Select-Object -First 1
  if ($config) {
    return $config.FullName
  }
  return ""
}

function Get-TunnelName {
  param([string]$Path)
  return [IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-ServiceName {
  param([string]$TunnelName)
  return "WireGuardTunnel`$$TunnelName"
}

function Get-ConfigAddress {
  param([string]$Path)
  $line = Get-Content -LiteralPath $Path -ErrorAction Stop |
    Where-Object { $_ -match '^\s*Address\s*=' } |
    Select-Object -First 1
  if (-not $line) {
    return ""
  }
  $value = ($line -replace '^\s*Address\s*=\s*', '').Split(',')[0].Trim()
  return ($value -replace '/\d+$', '')
}

function Ensure-Service {
  $wireguard = Ensure-WireGuardInstalled
  $config = Find-Config
  if ([string]::IsNullOrWhiteSpace($config)) {
    throw "Configuracao do suporte remoto ainda nao foi provisionada."
  }

  New-Item -ItemType Directory -Force -Path $supportRoot, $logDir | Out-Null
  $tunnelName = Get-TunnelName -Path $config
  $serviceName = Get-ServiceName -TunnelName $tunnelName
  $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

  if ($service) {
    if ($service.Status -eq "Running") {
      Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
      $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
    }
  } else {
    $output = & $wireguard /installtunnelservice $config 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw (($output | Out-String).Trim())
    }
  }

  return @{
    WireGuard = $wireguard
    Config = $config
    TunnelName = $tunnelName
    ServiceName = $serviceName
  }
}

function Get-Status {
  $wireguard = Find-WireGuardExe
  if ([string]::IsNullOrWhiteSpace($wireguard)) {
    $msi = Find-WireGuardMsi
    if (-not [string]::IsNullOrWhiteSpace($msi)) {
      return New-Result -Status "not_ready" -Installed $true -Connected $false -Message "Suporte remoto pronto para instalacao segura."
    }
    return New-Result -Status "not_ready" -Installed $false -Connected $false -Message "Componente WireGuard do suporte remoto ausente."
  }

  $config = Find-Config
  if ([string]::IsNullOrWhiteSpace($config)) {
    return New-Result -Status "not_ready" -Installed $true -Connected $false -Message "Suporte remoto aguardando autorizacao segura."
  }

  $tunnelName = Get-TunnelName -Path $config
  $serviceName = Get-ServiceName -TunnelName $tunnelName
  $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  $vpnIp = Get-ConfigAddress -Path $config
  $hostNameValue = if ([string]::IsNullOrWhiteSpace($Hostname)) { $env:COMPUTERNAME } else { $Hostname }

  if ($service -and $service.Status -eq "Running") {
    return New-Result -Status "connected" -Installed $true -Connected $true -VpnIp $vpnIp -HostnameValue $hostNameValue -Message "Suporte remoto permitido."
  }

  return New-Result -Status "disconnected" -Installed $true -Connected $false -VpnIp $vpnIp -HostnameValue $hostNameValue -Message "Suporte remoto desligado."
}

try {
  switch ($Action) {
    "ensure-service" {
      Ensure-Service | Out-Null
      Write-JsonResult (Get-Status)
    }
    "status" {
      Write-JsonResult (Get-Status)
    }
    "connect" {
      $info = Ensure-Service
      $service = Get-Service -Name $info.ServiceName -ErrorAction Stop
      if ($service.Status -ne "Running") {
        Start-Service -Name $info.ServiceName
        $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(20))
      }
      Write-JsonResult (Get-Status)
    }
    "disconnect" {
      $config = Find-Config
      if (-not [string]::IsNullOrWhiteSpace($config)) {
        $serviceName = Get-ServiceName -TunnelName (Get-TunnelName -Path $config)
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Running") {
          Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
          $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
        }
      }
      Write-JsonResult (Get-Status)
    }
  }
} catch {
  Write-JsonResult (New-Result -Status "error" -Installed (-not [string]::IsNullOrWhiteSpace((Find-WireGuardExe))) -Connected $false -Message "Suporte remoto indisponivel." -LastError $_.Exception.Message)
  exit 1
}
