function Invoke-DevTools($Socket, [int]$Id, [string]$Method, $Parameters, [int]$Timeout = 3500) {
    $request = @{ id = $Id; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 8 -Compress
    $packet = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($request))
    $token = [Threading.CancellationTokenSource]::new($Timeout)
    try {
        $null = $Socket.SendAsync($packet, 'Text', $true, $token.Token).GetAwaiter().GetResult()
        $buffer = [ArraySegment[byte]]::new([byte[]]::new(8192))
        do {
            $message = [IO.MemoryStream]::new()
            try {
                do {
                    $fragment = $Socket.ReceiveAsync($buffer, $token.Token).GetAwaiter().GetResult()
                    if ($fragment.MessageType -eq 'Close' -or $message.Length -gt 1048576) { throw 'Edge closed its session.' }
                    $message.Write($buffer.Array, 0, $fragment.Count)
                } until ($fragment.EndOfMessage)
                $reply = [Text.Encoding]::UTF8.GetString($message.ToArray()) | ConvertFrom-Json
            } finally { $message.Dispose() }
        } until ($reply.id -eq $Id)
        if ($reply.error -or $reply.result.exceptionDetails) { throw 'Edge could not perform the browser action.' }
        return $reply.result
    } finally { $token.Dispose() }
}

function Invoke-CampusLogin([uri]$Portal, [string]$Account, [Security.SecureString]$Password) {
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
    if (-not $edge) { return 'EdgeMissing' }

    $profile = Join-Path $DataDir "edge-$([guid]::NewGuid().ToString('N'))"
    $argsForEdge = @('--headless', '--incognito', '--no-first-run', '--no-default-browser-check',
        '--disable-background-networking', '--disable-extensions', '--no-proxy-server',
        '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
        "--user-data-dir=`"$profile`"", 'about:blank')
    $browser = $null
    $socket = $null
    try {
        $browser = Start-Process -FilePath $edge -ArgumentList $argsForEdge -WindowStyle Hidden -PassThru
        $portFile = Join-Path $profile 'DevToolsActivePort'
        $ready = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($portFile) -and -not $browser.HasExited -and $ready.Elapsed.TotalSeconds -lt 8) {
            Start-Sleep -Milliseconds 200
        }
        if (-not [IO.File]::Exists($portFile)) { return 'PortalUnavailable' }
        $port = [int]([IO.File]::ReadAllLines($portFile)[0])
        if ($port -lt 1 -or $port -gt 65535) { return 'PortalUnavailable' }
        $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 2 -UseBasicParsing
        $tab = $tabs | Where-Object { $_.type -eq 'page' -and $_.url -eq 'about:blank' } | Select-Object -First 1
        if ($tab.id -cnotmatch '^[a-fA-F0-9]{32}$') { return 'PortalUnavailable' }

        $socket = [Net.WebSockets.ClientWebSocket]::new()
        $socket.Options.Proxy = [Net.GlobalProxySelection]::GetEmptyWebProxy()
        $connectionTimeout = [Threading.CancellationTokenSource]::new(2500)
        try {
            $null = $socket.ConnectAsync([uri]"ws://127.0.0.1:$port/devtools/page/$($tab.id)", $connectionTimeout.Token).GetAwaiter().GetResult()
        } finally { $connectionTimeout.Dispose() }
        $navigation = Invoke-DevTools $socket 1 'Page.navigate' @{ url = $Portal.AbsoluteUri }
        if ($navigation.errorText) { return 'PortalUnavailable' }

        $site = @{
            origin = $Portal.GetLeftPart([UriPartial]::Authority)
            campusHost = $(if ($Portal.IdnHost -eq $CampusPortalHost) { $CampusPortalHost })
            httpsOnly = $Portal.Scheme -eq 'https'
        } | ConvertTo-Json -Compress
        $formScript = @'
((site, credentials) => {
  const campusPage = location.hostname === site.campusHost &&
    (location.protocol === 'https:' || (!site.httpsOnly && location.protocol === 'http:'));
  if (location.origin !== site.origin && !campusPage) return 'wrong-origin';
  const visible = el => el.getClientRects().length > 0 && getComputedStyle(el).visibility === 'visible';
  const editable = el => visible(el) && !el.disabled && !el.readOnly;
  const passwords = [...document.querySelectorAll('input[type=password]')].filter(editable);
  if (passwords.length !== 1) return 'no-form';
  const password = passwords[0];
  const form = password.form;
  const area = form || document;
  const accounts = [...area.querySelectorAll('input:not([type]), input[type=text], input[type=email], input[type=tel], input[type=number]')]
    .filter(editable);
  if (accounts.length !== 1 || area.querySelector('input[autocomplete=one-time-code]') ||
      [...area.querySelectorAll('input[type=checkbox][required]')].some(el => visible(el) && !el.checked)) return 'no-form';
  const controls = [...area.querySelectorAll('button,input[type=submit],input[type=button],[role=button],a,div[onclick],span[onclick]')].filter(visible);
  const loginText = /^(?:(?:登录|登錄|登陆|连接|連接)(?:[/／](?:login|signin|connect))?|login|signin|connect)$/i;
  const buttons = controls.filter(el => [el.value, el.innerText, el.textContent, el.getAttribute('aria-label')]
    .some(text => text && loginText.test(text.replace(/\s+/g, ''))));
  const submitters = controls.filter(el => el.type === 'submit' && el.form === form);
  const button = buttons.length === 1 ? buttons[0] : buttons.length === 0 && form && submitters.length === 1 ? submitters[0] : null;
  if (!button) return 'no-form';
  if (form) {
    const action = button.getAttribute('formaction') || form.getAttribute('action') || location.href;
    if (new URL(action, location.href).origin !== location.origin) return 'no-form';
  }
  if (!credentials) return 'ready';
  if (form && (button.getAttribute('formmethod') || form.method).toLowerCase() === 'get') {
    // Preserve JavaScript handlers while preventing a native GET that would put the password in the URL.
    window.addEventListener('submit', event => { if (event.target === form) event.preventDefault(); }, true);
  }
  const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  for (const [input, value] of [[accounts[0], credentials.account], [password, credentials.password]]) {
    setValue.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }
  if (button.disabled || button.getAttribute('aria-disabled') === 'true') return 'no-form';
  button.click();
  return 'submitted';
})
'@
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $id = 2
        $seenPortal = $false
        do {
            $page = Invoke-DevTools $socket $id 'Runtime.evaluate' @{
                expression = "$formScript($site,null)"; returnByValue = $true
            }
            $state = $page.result.value
            if ($state -ne 'wrong-origin') { $seenPortal = $true }
            if ($state -eq 'ready') { break }
            Start-Sleep -Milliseconds 350
            $id++
        } while ($watch.Elapsed.TotalSeconds -lt 9)

        if ($state -ne 'ready') {
            if ($seenPortal) { return 'FormUnsupported' }
            return 'PortalUnavailable'
        }
        if ((Get-WifiState) -ne 'Connected') { return 'WifiConnectFailed' }

        $id++
        $plain = [Net.NetworkCredential]::new('', $Password).Password
        $credentialsJson = @{ account = $Account; password = $plain } | ConvertTo-Json -Compress
        try {
            $result = Invoke-DevTools $socket $id 'Runtime.evaluate' @{
                expression = "$formScript($site,$credentialsJson)"; returnByValue = $true
            }
        } finally {
            $plain = $null
            $credentialsJson = $null
        }
        if ($result.result.value -ne 'submitted') { return 'FormUnsupported' }

        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            Start-Sleep -Seconds 2
            if (Test-ExternalNetwork) { return 'LoginSubmitted' }
        }
        return 'LoginUnconfirmed'
    } catch {
        return 'PortalUnavailable'
    } finally {
        if ($socket) { $socket.Dispose() }
        if ($browser) {
            try { if (-not $browser.HasExited) { $browser.Kill(); $null = $browser.WaitForExit(1500) } }
            catch { }
            finally { $browser.Dispose() }
        }
        try {
            $profileItem = Get-Item -LiteralPath $profile -ErrorAction SilentlyContinue
            $parent = (Get-Item -LiteralPath $DataDir).FullName
            if ($profileItem -and $profileItem.Parent.FullName -eq $parent -and
                $profileItem.Name -cmatch '^edge-[a-f0-9]{32}$' -and
                -not ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Remove-Item -LiteralPath $profileItem.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}
