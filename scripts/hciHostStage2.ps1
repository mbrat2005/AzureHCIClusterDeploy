Function log {
    Param (
        [string]$message,
        [string]$logPath = 'C:\temp\hciHostDeploy.log'
    )

    If (!(Test-Path -Path C:\temp)) {
        New-Item -Path C:\temp -ItemType Directory
    }
    
    Write-Host $message
    Add-Content -Path $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $message"
}

$ErrorActionPreference = 'Stop'

If (Test-Path -path 'C:\Reboot1Required.status') {
    log "Reboot 1 is required"

    Remove-Item 'C:\Reboot1Required.status'
    Set-Content -Path 'C:\Reboot1Initiated.status' -Value 'Reboot 1 Initiated'

    $action = New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '-r -f -t 0'
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount
    $task = New-ScheduledTask -Action $action -Description 'Reboot 1' -Trigger $trigger -Principal $principal
    Register-ScheduledTask -TaskName 'Reboot1' -InputObject $task

    Start-Sleep -Seconds 75
}
ElseIf (Test-Path -path 'C:\Reboot1Initiated.status') {
    log "Reboot 1 has been initiated and now completed"

    Remove-Item 'C:\Reboot1Initiated.status'
    Set-Content -Path 'C:\Reboot1Completed.status' -Value 'Reboot 1 Completed'
}
ElseIf (Test-Path -path 'C:\Reboot1Completed.status') {
    log "Reboot 1 has been completed"
}