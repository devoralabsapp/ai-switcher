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
$env:USERPROFILE=[Environment]::GetFolderPath('UserProfile')
$env:LOCALAPPDATA=Join-Path $env:USERPROFILE 'AppData\Local'
$env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming'
$env:TEMP=Join-Path $env:LOCALAPPDATA 'Temp'
$env:TMP=$env:TEMP
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
$root=Join-Path $env:TEMP ('ai-switcher-smoke.'+[Guid]::NewGuid().ToString('N'))
$output=Join-Path $scope 'results'
New-Item -ItemType Directory -Path $output -Force | Out-Null
try {
    $app=Join-Path $scope 'AISwitcher.exe'
    $cli=(Get-ChildItem (Join-Path $scope 'tools') -Recurse -Filter codex.exe | Where-Object {$_.FullName -match 'x86_64-pc-windows-msvc'} | Select-Object -First 1).FullName
    $p=Start-Process $app -ArgumentList @('--data-dir',"`"$root`"",'--output',"`"$output`"",'--backend-smoke-test','--codex-executable',"`"$cli`"") -PassThru
    if(-not $p.WaitForExit(240000)){$p.Kill();throw 'Backend smoke timed out'}
    if($p.ExitCode -ne 0){throw 'Backend smoke failed'}
    Remove-Item -Recurse -Force $root
} catch {
    Add-Content (Join-Path $output 'backend-smoke-error.txt') $_.Exception.Message
    exit 1
}
exit 0
'@ | Set-Content $script -Encoding utf8
    $credential=[PSCredential]::new("$env:COMPUTERNAME\$name",$password)
    $process=Start-Process 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Credential $credential -LoadUserProfile -WorkingDirectory $scope -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$script`"") -PassThru
    if(-not $process.WaitForExit(270000)){$process.Kill();throw 'Ordinary-user Windows smoke timed out'}
    Copy-Item (Join-Path $scope 'results/*') $Output -Force
    if($process.ExitCode -ne 0){Get-Content (Join-Path $Output 'backend-smoke-error.txt');throw 'Ordinary-user Windows backend smoke failed'}
    Get-Content (Join-Path $Output 'backend-smoke-result.txt')
} finally {
    if($created){Remove-LocalUser -Name $name}
    if(Test-Path $scope){Remove-Item $scope -Recurse -Force}
}
