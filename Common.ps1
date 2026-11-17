$ErrorActionPreference = 'Stop'

$script:CampusSsid = 'scut-student'
$script:CampusPortalHost = 's.scut.edu.cn'
$script:DefaultPortalAddress = "http://$CampusPortalHost/"
$script:DataDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ScutWifiHelper'
$script:ConfigFile = Join-Path $DataDir 'settings.json'
$script:StatusFile = Join-Path $DataDir 'status.json'
$script:RetryFile = Join-Path $DataDir 'last-attempt.json'
$script:LockFile = Join-Path $DataDir 'check.lock'
$script:WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'

function Read-LocalJson($Path) {
    if ([IO.File]::Exists($Path)) {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        $reader = New-Object IO.StreamReader -ArgumentList $stream
        try { $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
    }
}

function Write-LocalJson($Path, $Value) {
    $null = [IO.Directory]::CreateDirectory($DataDir)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding $false))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Protect-LocalPassword([string]$Password) {
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::Unicode.GetBytes($Password)
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser')
        # Keep the DPAPI hex format used by settings saved by earlier versions.
        return [BitConverter]::ToString($encrypted).Replace('-', '').ToLowerInvariant()
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Unprotect-LocalPassword([string]$StoredPassword) {
    if ($StoredPassword -notmatch '\A(?:[a-f0-9]{2})+\z') {
        throw '已保存的密码格式无效。'
    }
    Add-Type -AssemblyName System.Security
    $encrypted = [byte[]]::new($StoredPassword.Length / 2)
    for ($index = 0; $index -lt $encrypted.Length; $index++) {
        $encrypted[$index] = [Convert]::ToByte($StoredPassword.Substring(2 * $index, 2), 16)
    }

    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, 'CurrentUser')
    $password = $null
    try {
        if (($bytes.Length % 2) -ne 0) { throw '已保存的密码格式无效。' }
        $password = [Security.SecureString]::new()
        for ($offset = 0; $offset -lt $bytes.Length; $offset += 2) {
            $password.AppendChar([BitConverter]::ToChar($bytes, $offset))
        }
        $password.MakeReadOnly()
        return $password
    } catch {
        if ($password) { $password.Dispose() }
        throw
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-PortalUri([string]$Address) {
    if ($Address -eq $CampusPortalHost) { $Address = $DefaultPortalAddress }
    $uri = $null
    if (-not [uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('https', 'http') -or -not $uri.Host -or $uri.UserInfo) {
        throw '认证页地址应以 https:// 或 http:// 开头，且地址中不能含有用户名或密码。'
    }
    $uri
}

function Resolve-PortalAddress([string]$SavedAddress, [string]$Redirect) {
    $saved = Get-PortalUri $SavedAddress
    $candidate = $null
    if ($saved.IdnHost -eq $CampusPortalHost -and
        [uri]::TryCreate($Redirect, [UriKind]::Absolute, [ref]$candidate) -and
        $candidate.IdnHost -eq $CampusPortalHost -and -not $candidate.UserInfo -and
        ($candidate.Scheme -eq 'https' -or ($saved.Scheme -eq 'http' -and $candidate.Scheme -eq 'http'))) {
        return $candidate
    }
    return $saved
}

function Get-WifiState {
    $lines = & $Netsh wlan show interfaces 2>&1
    $code = $LASTEXITCODE
    $details = $lines -join "`n"
    if ($code -ne 0) {
        if ($details -match 'access is denied|location|requires elevation|error\s*5\b|位置|拒绝访问|提升') {
            return 'LocationRequired'
        }
        return 'WifiUnavailable'
    }
    if ($details -cmatch '(?m)^\s*SSID\s*:\s*scut-student[ \t]*\r?$') { return 'Connected' }
    return 'Disconnected'
}

function Connect-CampusWifi {
    # Check visibility first, so the script leaves other Wi-Fi connections alone off campus.
    $available = & $Netsh wlan show networks 2>&1
    if ($LASTEXITCODE -ne 0) { return 'WifiUnavailable' }
    if (($available -join "`n") -cnotmatch '(?m)^\s*SSID\s+\d+\s*:\s*scut-student[ \t]*\r?$') {
        return 'WifiNotFound'
    }

    # A manually saved Windows profile is needed for the first connection.
    $null = & $Netsh wlan show profile "name=$CampusSsid" 2>&1
    if ($LASTEXITCODE -ne 0) { return 'WifiProfileMissing' }
    $null = & $Netsh wlan connect "name=$CampusSsid" "ssid=$CampusSsid" 2>&1
    if ($LASTEXITCODE -ne 0) { return 'WifiConnectFailed' }
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        Start-Sleep -Seconds 1
        if ((Get-WifiState) -eq 'Connected') { return 'Connected' }
    }
    return 'WifiConnectFailed'
}

function Test-ExternalNetwork([ref]$PortalRedirect) {
    # Use the small Windows connectivity probe without following captive portal redirects.
    $request = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
    $request.AllowAutoRedirect = $false
    $request.Proxy = $null
    $request.Timeout = 3500
    $request.ReadWriteTimeout = 2000
    $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy -ArgumentList ([Net.Cache.RequestCacheLevel]::BypassCache)
    try {
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            if ($status -ne 200) {
                if ($PortalRedirect -and $status -in @(301, 302, 303, 307, 308)) {
                    $PortalRedirect.Value = $response.Headers['Location']
                }
                return $false
            }
            $reader = New-Object IO.StreamReader -ArgumentList ($response.GetResponseStream())
            try {
                $buffer = New-Object char[] 64
                $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
                return ([string]::new($buffer, 0, $length).Trim() -ceq 'Microsoft Connect Test')
            } finally { $reader.Dispose() }
        } finally { $response.Dispose() }
    } catch [Net.WebException] {
        if ($_.Exception.Response) { $_.Exception.Response.Dispose() }
        return $false
    }
}

$script:Messages = @{
    WifiUnavailable    = '无法读取 Wi-Fi。请检查无线网卡和 WLAN AutoConfig 服务。'
    LocationRequired   = 'Windows 限制读取 Wi-Fi。请检查「设置 → 隐私和安全性 → 位置」的桌面应用访问权限。'
    WifiNotFound       = '附近暂未找到 scut-student，将继续检查。'
    WifiProfileMissing = '请先从 Windows 的 Wi-Fi 菜单手动连接一次 scut-student。'
    WifiConnectFailed  = '已尝试重连，但 Wi-Fi 连接未建立。'
    Online             = '校园 Wi-Fi 已连接，外网探测通过。'
    Reconnected        = '已重新连接校园 Wi-Fi，外网探测通过。'
    QuietHours         = '外网不可用。自动认证将在早上 06:00 恢复。'
    ConfigMissing      = '外网不可用。请先保存认证页地址和校园网账号密码。'
    Cooldown           = '外网仍不可用。等待下一次认证尝试。'
    EdgeMissing        = '未找到 Microsoft Edge，无法打开认证页。'
    PortalUnavailable  = '认证页暂时打不开，或页面地址与已保存的认证入口不同。'
    FormUnsupported    = '未识别到可填写的登录表单。请检查是否有验证码、服务商选项或页面改版。'
    LoginSubmitted     = '已提交校园网登录，外网探测通过。'
    LoginUnconfirmed   = '已提交校园网登录，但外网探测未通过。请手动核对账号或网页提示。'
    CredentialError    = '无法读取已保存的密码。请用当前 Windows 用户重新保存。'
    Unexpected         = '检查中断。请重试，或检查 Windows、Edge 和校园网状态。'
}
