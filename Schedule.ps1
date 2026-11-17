$script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:TaskName = "ScutWifiHelper-$UserSid"

function Get-ReconnectTask {
    Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
}

function New-ReconnectAction {
    $launcher = Join-Path $PSScriptRoot '校园网设置.exe'
    New-ScheduledTaskAction -Execute $launcher -Argument 'background'
}

function New-ReconnectTaskDefinition {
    $action = New-ReconnectAction
    $start = [DateTime]::Today.AddHours(6)
    $interval = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 1)
    $daily = New-ScheduledTaskTrigger -Daily -At $start
    $daily.Repetition = $interval.Repetition
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $UserSid
    $principal = New-ScheduledTaskPrincipal -UserId $UserSid -LogonType Interactive -RunLevel Limited
    $options = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    New-ScheduledTask -Action $action -Trigger @($daily, $logon) -Principal $principal -Settings $options `
        -Description 'Check scut-student Wi-Fi and restore campus portal sign-in.'
}

function Enable-ReconnectTask {
    $definition = New-ReconnectTaskDefinition
    $null = Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -InputObject $definition -Force
    Start-ScheduledTask -TaskName $TaskName -TaskPath '\'
}
