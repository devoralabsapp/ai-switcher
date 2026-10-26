# CI-only: Codex deliberately refuses elevated daemons. Hosted Windows runners
# are administrators, so exercise the app as a temporary ordinary local user.
param(
    [Parameter(Mandatory=$true)][string]$App,
    [Parameter(Mandatory=$true)][string]$Tools,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference='Stop'
$name='aisw'+[Guid]::NewGuid().ToString('N').Substring(0,10)
$scope=Join-Path $env:PUBLIC ('ai-switcher-backend.'+[Guid]::NewGuid().ToString('N'))
$created=$false
$taskRegistered=$false
$taskName='AI-Switcher-Smoke-'+$name
try {
    New-Item -ItemType Directory -Path $scope,$Output -Force | Out-Null
    $password=ConvertTo-SecureString ('Aa1!'+[Guid]::NewGuid().ToString('N')) -AsPlainText -Force
    New-LocalUser -Name $name -Password $password -AccountNeverExpires -PasswordNeverExpires | Out-Null
    $created=$true
    & icacls.exe $scope /grant "${name}:(OI)(CI)F" | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not prepare disposable test directory'}
    Copy-Item $App (Join-Path $scope 'AISwitcher.exe')
    Copy-Item $Tools (Join-Path $scope 'tools') -Recurse
    $script=Join-Path $scope 'probe.ps1'
    @'
$ErrorActionPreference='Stop'
$scope=$PSScriptRoot
$output=Join-Path $scope 'results'
New-Item -ItemType Directory -Path $output -Force | Out-Null
try {
$env:USERPROFILE=[Environment]::GetFolderPath('UserProfile')
$env:LOCALAPPDATA=Join-Path $env:USERPROFILE 'AppData\Local'
$env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming'
$env:TEMP=Join-Path $env:LOCALAPPDATA 'Temp'
$env:TMP=$env:TEMP
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
$root=Join-Path $env:TEMP ('ai-switcher-smoke.'+[Guid]::NewGuid().ToString('N'))
    $app=Join-Path $scope 'AISwitcher.exe'
    $cli=(Get-ChildItem (Join-Path $scope 'tools') -Recurse -Filter codex.exe | Where-Object {$_.FullName -match 'x86_64-pc-windows-msvc'} | Select-Object -First 1).FullName
    $p=Start-Process $app -ArgumentList @('--data-dir',"`"$root`"",'--output',"`"$output`"",'--backend-smoke-test','--codex-executable',"`"$cli`"") -PassThru
    if(-not $p.WaitForExit(240000)){$p.Kill();throw 'Backend smoke timed out'}
    if($p.ExitCode -ne 0){throw 'Backend smoke failed'}
    Remove-Item -Recurse -Force $root
} catch {
    Add-Content (Join-Path $output 'backend-smoke-error.txt') $_.Exception.Message
    Set-Content (Join-Path $scope 'exit-code.txt') '1'
    exit 1
}
Set-Content (Join-Path $scope 'exit-code.txt') '0'
exit 0
'@ | Set-Content $script -Encoding utf8
    $credential=[PSCredential]::new("$env:COMPUTERNAME\$name",$password)
    # Task Scheduler starts outside the runner's restrictive job object, just
    # as launching the installed app from Explorer does. No elevation is used.
    $action=New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument "-NoProfile -NonInteractive -Command `"& '$script' *> '$scope\wrapper.log'`"" -WorkingDirectory $scope
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $settings.AllowDemandStart=$true
    $settings.RunOnlyIfIdle=$false
    $settings.RunOnlyIfNetworkAvailable=$false
    $trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(5))
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User $credential.UserName -Password $credential.GetNetworkCredential().Password -RunLevel Limited | Out-Null
    $taskRegistered=$true
    Start-ScheduledTask -TaskName $taskName
    $started=(Get-Date).AddSeconds(-2)
    $deadline=(Get-Date).AddSeconds(270)
    while(-not (Test-Path (Join-Path $scope 'exit-code.txt'))){
        if((Get-Date) -gt $deadline){Stop-ScheduledTask -TaskName $taskName;throw ('Ordinary-user Windows smoke timed out; task state: '+(Get-ScheduledTask -TaskName $taskName).State+'; result: '+(Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult)}
        Start-Sleep -Seconds 1
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        if((Get-Date) -gt $started.AddSeconds(60) -and $info.LastRunTime -lt $started){throw ('Windows task did not start; state: '+(Get-ScheduledTask -TaskName $taskName).State+'; result: '+$info.LastTaskResult)}
        if((Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -and $info.LastRunTime -gt $started -and -not (Test-Path (Join-Path $scope 'exit-code.txt'))){
            if(Test-Path (Join-Path $scope 'wrapper.log')){Get-Content (Join-Path $scope 'wrapper.log')}
            throw ('Windows task exited without a result: '+$info.LastTaskResult)
        }
    }
    $exitCode=[int](Get-Content (Join-Path $scope 'exit-code.txt'))
    Copy-Item (Join-Path $scope 'results/*') $Output -Force
    if($exitCode -ne 0){Get-Content (Join-Path $Output 'backend-smoke-error.txt');throw 'Ordinary-user Windows backend smoke failed'}
    Get-Content (Join-Path $Output 'backend-smoke-result.txt')
} finally {
    if(Test-Path (Join-Path $scope 'wrapper.log')){Copy-Item (Join-Path $scope 'wrapper.log') (Join-Path $Output 'backend-wrapper.log') -Force}
    if(Test-Path (Join-Path $scope 'results')){Copy-Item (Join-Path $scope 'results/*') $Output -Force}
    if($taskRegistered){Stop-ScheduledTask -TaskName $taskName;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    if($created){Remove-LocalUser -Name $name}
    if(Test-Path $scope){Remove-Item $scope -Recurse -Force}
}
