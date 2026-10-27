param([Parameter(Mandatory=$true)][string]$App,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$scope=Join-Path $env:TEMP ('ai-switcher-vendor.'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scope,$Output -Force | Out-Null
$package=Join-Path $scope 'Claude.msix'
$installed=$null
try {
    # Official offline Store payload, never an account or authenticated download.
    & curl.exe --fail --location --retry 2 --output $package 'https://api.anthropic.com/api/desktop/win32/x64/msix/latest/redirect'
    if($LASTEXITCODE -ne 0){throw 'Official MSIX download failed'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($package)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry('AppxManifest.xml').Open())
        try{[xml]$manifest=$reader.ReadToEnd()}finally{$reader.Dispose()}
    }finally{$zip.Dispose()}
    $version=$manifest.Package.Identity.Version
    $source=$null
    try {
        $env:AISW_FIXTURE_PACKAGE=$package
        $metadata=& powershell.exe -NoProfile -NonInteractive -Command '$ErrorActionPreference="Stop"; Add-AppxPackage -Path $env:AISW_FIXTURE_PACKAGE -ErrorAction Stop; Get-AppxPackage -Name Claude | Where-Object {$_.PublisherId -eq "pzs8sxrjxfjjc"} | Select-Object -First 1 InstallLocation,PackageFullName | ConvertTo-Json -Compress'
        if($LASTEXITCODE -ne 0){throw 'Windows declined package registration'}
        $installed=$metadata | ConvertFrom-Json
        if($installed){$source=Join-Path $installed.InstallLocation 'app/Claude.exe'}
    } catch {
        # Server runners can lack Store deployment support. Record this distinction.
        "Registered-package setup unavailable: HRESULT $($_.Exception.HResult)" | Set-Content (Join-Path $Output 'store-package-deployment.txt')
    }
    if(-not $source -or -not (Test-Path $source)){
        $unpacked=Join-Path $scope 'official-payload'
        [IO.Compression.ZipFile]::ExtractToDirectory($package,$unpacked)
        $source=Join-Path $unpacked 'app/Claude.exe'
        "Mode: official MSIX extracted payload; version $version" | Set-Content (Join-Path $Output 'store-package-mode.txt')
    } else {
        "Mode: registered Microsoft-signed MSIX in WindowsApps; version $version" | Set-Content (Join-Path $Output 'store-package-mode.txt')
    }
    $root=Join-Path $env:TEMP ('ai-switcher-smoke.'+[Guid]::NewGuid().ToString('N'))
    $process=Start-Process $App -ArgumentList @('--data-dir',"`"$root`"",'--output',"`"$Output`"",'--store-runtime-smoke-test','--store-agent','claude','--store-executable',"`"$source`"") -PassThru
    if(-not $process.WaitForExit(360000)){$process.Kill();throw 'Real Claude Store runtime smoke timed out'}
    if($process.ExitCode -ne 0){if(Test-Path (Join-Path $Output 'store-runtime-error.txt')){Get-Content (Join-Path $Output 'store-runtime-error.txt')};throw 'Real Claude Store runtime smoke failed'}
    Get-Content (Join-Path $Output 'store-package-mode.txt'),(Join-Path $Output 'store-runtime-result.txt'),(Join-Path $Output 'store-runtime-reopen-result.txt')
    Remove-Item $root -Recurse -Force
}finally{
    if($installed){$env:AISW_FIXTURE_FULLNAME=$installed.PackageFullName;& powershell.exe -NoProfile -NonInteractive -Command 'Remove-AppxPackage -Package $env:AISW_FIXTURE_FULLNAME -ErrorAction Continue'}
    Remove-Item $scope -Recurse -Force
}
