param([switch]$Manual)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-ConnectionCheck {
    $wifi = Get-WifiState
    $reconnected = $false
    if ($wifi -eq 'Disconnected') {
        $wifi = Connect-CampusWifi
        $reconnected = $true
    }
    if ($wifi -ne 'Connected') { return $wifi }
    $redirect = $null
    if (Test-ExternalNetwork ([ref]$redirect)) {
        [IO.File]::Delete($RetryFile)
        if ($reconnected) { return 'Reconnected' }
        return 'Online'
    }
    if (-not $Manual -and (Get-Date).Hour -lt 6) { return 'QuietHours' }

    $config = Read-LocalJson $ConfigFile
    if (-not ($config.Portal -and $config.Account -and $config.Password)) { return 'ConfigMissing' }
    $retry = Read-LocalJson $RetryFile
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if (-not $Manual -and $retry -and $retry.Revision -eq $config.Revision -and $now -lt $retry.Next) {
        return 'Cooldown'
    }

    $portal = Resolve-PortalAddress $config.Portal $redirect
    try { $password = Unprotect-LocalPassword $config.Password }
    catch { return 'CredentialError' }
    try {
        # Persist the cooldown before starting Edge so interrupted tests do not submit repeatedly.
        Write-LocalJson $RetryFile @{ Revision = $config.Revision; Next = $now + 300 }
        . (Join-Path $PSScriptRoot 'Portal.ps1')
        $result = Invoke-CampusLogin $portal $config.Account $password
        if ($result -eq 'LoginSubmitted') { [IO.File]::Delete($RetryFile) }
        return $result
    } finally { $password.Dispose() }
}

$null = [IO.Directory]::CreateDirectory($DataDir)
try { $lock = [IO.File]::Open($LockFile, 'OpenOrCreate', 'Write', 'None') }
catch [IO.IOException] { exit 2 }
try {
    try { $code = Invoke-ConnectionCheck }
    catch { $code = 'Unexpected' }
    Write-LocalJson $StatusFile @{
        Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Code = $code; Message = $Messages[$code]
    }
} finally { $lock.Dispose() }
