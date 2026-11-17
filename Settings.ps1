. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Schedule.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$window = [Windows.Forms.Form]::new()
$window.Text = '校园网自动重连'
$window.ClientSize = [Drawing.Size]::new(535, 371)
$window.AutoScaleMode = 'Dpi'
$window.FormBorderStyle = 'FixedDialog'
$window.MaximizeBox = $false
$window.StartPosition = 'CenterScreen'
$window.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
$window.BackColor = [Drawing.Color]::White
$window.ForeColor = [Drawing.Color]::FromArgb(31, 45, 62)

function Add-Label($Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.SetBounds($X, $Y, $Width, $Height)
    $window.Controls.Add($label)
    return $label
}

function Add-Field($Caption, [int]$Y, [bool]$IsPassword = $false) {
    $null = Add-Label $Caption 26 ($Y + 3) 92 28
    $field = [Windows.Forms.TextBox]::new()
    $field.UseSystemPasswordChar = $IsPassword
    $field.SetBounds(126, $Y, 382, 26)
    $field.AccessibleName = $Caption
    $window.Controls.Add($field)
    return $field
}

function Add-Button($Text, [int]$X, [int]$Width) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.SetBounds($X, 207, $Width, 37)
    $window.Controls.Add($button)
    return $button
}

$title = Add-Label 'scut-student' 25 20 480 33
$title.Font = [Drawing.Font]::new('Microsoft YaHei UI', 17, [Drawing.FontStyle]::Bold)
$portalField = Add-Field '认证页地址' 65
$portalField.Text = $DefaultPortalAddress
$accountField = Add-Field '校园网账号' 103
$passwordField = Add-Field '校园网密码' 141 $true
$passwordHelp = Add-Label '密码保存在本机。已保存的密码留空即保留。' 125 171 390 25
$passwordHelp.ForeColor = [Drawing.Color]::FromArgb(85, 96, 109)
$saveButton = Add-Button '保存设置' 26 121
$testButton = Add-Button '立即检查' 156 121
$autoButton = Add-Button '启用自动重连' 286 222
$saveButton.FlatStyle = 'Flat'
$saveButton.FlatAppearance.BorderSize = 0
$saveButton.BackColor = [Drawing.Color]::FromArgb(13, 74, 105)
$saveButton.ForeColor = [Drawing.Color]::White

$autoLabel = Add-Label '' 26 263 482 26
$statusLabel = Add-Label '最近检查  暂无记录。' 26 292 484 72
$statusLabel.ForeColor = [Drawing.Color]::FromArgb(66, 83, 102)
$window.AcceptButton = $saveButton

function Show-SettingsError($Message) {
    $null = [Windows.Forms.MessageBox]::Show($window, $Message, '校园网自动重连', 'OK', 'Warning')
}

function Update-TaskDisplay {
    $task = Get-ReconnectTask
    $script:AutoEnabled = [bool]($task -and $task.State -ne 'Disabled')
    if ($AutoEnabled) {
        $autoLabel.Text = '自动重连已启用，每分钟检查。00:00–06:00 暂停自动登录。'
        $autoButton.Text = '暂停自动重连'
    } else {
        $autoLabel.Text = '自动重连已暂停。'
        $autoButton.Text = '启用自动重连'
    }
}

function Update-StatusDisplay {
    $status = Read-LocalJson $StatusFile
    if ($status) { $statusLabel.Text = "最近检查  $($status.Time)`r`n$($status.Message)" }
}

function Save-NetworkSettings {
    $portal = Get-PortalUri $portalField.Text.Trim()
    $account = $accountField.Text.Trim()
    if (-not $account) { throw '请输入校园网账号。' }
    $previous = Read-LocalJson $ConfigFile
    if ($passwordField.Text.Length -gt 0) {
        $storedPassword = Protect-LocalPassword $passwordField.Text
    } else {
        if (-not $previous.Password -or $previous.Account -cne $account -or $previous.Portal -cne $portal.AbsoluteUri) {
            throw '请填写密码。更换账号或认证地址后，请重新输入密码。'
        }
        $storedPassword = $previous.Password
    }
    Write-LocalJson $ConfigFile @{
        Account = $account; Password = $storedPassword; Portal = $portal.AbsoluteUri
        Revision = [guid]::NewGuid().ToString('N')
    }
    $passwordField.Clear()
}

$saveButton.Add_Click({
    try {
        Save-NetworkSettings
        $statusLabel.Text = '设置已保存。点击「立即检查」查看当前连接状态。'
    } catch { Show-SettingsError $_.Exception.Message }
})

$script:ManualCheck = $null
$testButton.Add_Click({
    try {
        $testButton.Enabled = $false
        $worker = Join-Path $PSScriptRoot 'Check.ps1'
        $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$worker`" -Manual"
        $script:ManualCheck = Start-Process -FilePath $WindowsPowerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $statusLabel.Text = '正在检查 Wi-Fi 和已保存的登录设置…'
    } catch {
        $testButton.Enabled = $true
        Show-SettingsError '无法启动检查。请确认 Windows PowerShell 可用。'
    }
})

$autoButton.Add_Click({
    try {
        if ($AutoEnabled) {
            $null = Disable-ScheduledTask -TaskName $TaskName -TaskPath '\'
        } else {
            Enable-ReconnectTask
        }
    } catch { Show-SettingsError "无法修改 Windows 计划任务。`r`n$($_.Exception.Message)" }
    try { Update-TaskDisplay } catch { $autoLabel.Text = '无法读取 Windows 计划任务状态。' }
})

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 1000
$script:DisplayedStatusTime = $null
$timer.Add_Tick({
    try {
        if ($ManualCheck) {
            if (-not $ManualCheck.HasExited) { return }
            $exitCode = $ManualCheck.ExitCode
            $ManualCheck.Dispose()
            $script:ManualCheck = $null
            $testButton.Enabled = $true
            if ($exitCode -eq 2) { $statusLabel.Text = '后台检查正在运行，请稍后查看结果。'; return }
            if ($exitCode -ne 0) { $statusLabel.Text = '检查未能完成。请重新打开窗口再试。'; return }
        }
        $status = Read-LocalJson $StatusFile
        if ($status -and $status.Time -ne $DisplayedStatusTime) {
            Update-StatusDisplay
            $script:DisplayedStatusTime = $status.Time
        }
    } catch { $statusLabel.Text = '暂时无法读取最近检查结果。' }
})

try {
    $config = Read-LocalJson $ConfigFile
    if ($config) {
        $portalField.Text = $config.Portal
        $accountField.Text = $config.Account
    }
    $status = Read-LocalJson $StatusFile
    if ($status) { $script:DisplayedStatusTime = $status.Time; Update-StatusDisplay }
} catch { $statusLabel.Text = '本机设置无法读取。请重新保存。' }
try { Update-TaskDisplay } catch { $autoLabel.Text = '无法读取 Windows 计划任务状态。' }
$timer.Start()
try { $null = $window.ShowDialog() }
finally { $timer.Dispose(); $window.Dispose(); if ($ManualCheck) { $ManualCheck.Dispose() } }
