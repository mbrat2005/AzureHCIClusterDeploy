
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

# check for reboot status file, reboot if needed
If (Test-Path -path 'C:\Reboot2Required.status') {
    log "Reboot 2 is required"

    Remove-Item 'C:\Reboot2Required.status'
    Set-Content -Path 'C:\Reboot2Initiated.status' -Value 'Reboot 2 Initiated'

    # use scheduled task to reboot the machine, ensuring the runCommand exits gracefully
    $action = New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '-r -f -t 0'
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount
    $task = New-ScheduledTask -Action $action -Description 'Reboot 2' -Trigger $trigger -Principal $principal
    Register-ScheduledTask -TaskName 'Reboot2' -InputObject $task
}
ElseIf (Test-Path -path 'C:\Reboot2Initiated.status') {
    log "Reboot 2 has been initiated and now completed"

    Remove-Item 'C:\Reboot2Initiated.status'
    Set-Content -Path 'C:\Reboot2Completed.status' -Value 'Reboot 2 Completed'
}
ElseIf (Test-Path -path 'C:\Reboot2Completed.status') {
    log "Reboot 2 has been completed"
}
