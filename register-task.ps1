param(
    [string]$TaskName = "FDA-GTx104-Tracker",
    [string]$ConfigPath = ".\tracker-config.json",
    [int]$EveryMinutes = 15
)

$ErrorActionPreference = "Stop"

if ($EveryMinutes -lt 1) {
    throw "EveryMinutes must be at least 1."
}

$scriptPath = Join-Path $PSScriptRoot "run-tracker.ps1"
$resolvedConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
} else {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $ConfigPath))
}

$actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$resolvedConfigPath`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs

$startAt = (Get-Date).AddMinutes(1)
$trigger = New-ScheduledTaskTrigger -Once -At $startAt
$trigger.RepetitionInterval = (New-TimeSpan -Minutes $EveryMinutes)
$trigger.RepetitionDuration = (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Scheduled task '$TaskName' created. It will poll every $EveryMinutes minute(s)."
