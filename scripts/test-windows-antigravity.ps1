param([Parameter(Mandatory=$true)][string]$App,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$scope=Join-Path $env:TEMP ('ai-switcher-vendor.'+[Guid]::NewGuid().ToString('N'))
$root=Join-Path $env:TEMP ('ai-switcher-smoke.'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scope,$Output -Force | Out-Null
try {
    # Public, official Hub payload; never execute its installer or sign into a real account.
    $installer=Join-Path $scope 'Antigravity-x64.exe'
    & curl.exe --fail --location --retry 2 --output $installer 'https://storage.googleapis.com/antigravity-public/antigravity-hub/2.28.2-5937220255875072/windows-x64/Antigravity-x64.exe'
    if($LASTEXITCODE -ne 0){throw 'Official Antigravity Hub download failed'}
    $signature=Get-AuthenticodeSignature $installer
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Google'){throw 'Antigravity installer signature could not be verified'}
    $unpacked=Join-Path $scope 'program'
    & 7z.exe x $installer "-o$unpacked" -y | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not extract official Antigravity installer'}
    foreach($archive in @(Get-ChildItem $unpacked -Recurse -Filter '*.7z')){
        & 7z.exe x $archive.FullName "-o$unpacked/app" -y | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Could not extract official Antigravity program files'}
    }
    $desktop=Get-ChildItem $unpacked -Recurse -Filter 'Antigravity.exe' | Where-Object {Test-Path (Join-Path $_.DirectoryName 'resources/bin/language_server.exe')} | Select-Object -First 1
    if(-not $desktop){throw 'Official native Antigravity server was not found'}
    $manifest=Invoke-RestMethod 'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/windows_amd64.json'
    $uri=[Uri]$manifest.url
    if($uri.Scheme -ne 'https' -or $uri.Host -ne 'storage.googleapis.com'){throw 'Unexpected official CLI download origin'}
    $cli=Join-Path $scope 'agy.exe'
    & curl.exe --fail --location --retry 2 --output $cli $manifest.url
    if($LASTEXITCODE -ne 0){throw 'Official Antigravity CLI download failed'}
    if((Get-FileHash $cli -Algorithm SHA512).Hash.ToLowerInvariant() -ne $manifest.sha512.ToLowerInvariant()){throw 'Official CLI checksum mismatch'}
    "Hub: $($desktop.VersionInfo.ProductVersion); CLI: $($manifest.version); synthetic Credential Manager fixture only" | Set-Content (Join-Path $Output 'antigravity-vendor-versions.txt')
    $process=Start-Process $App -ArgumentList @('--data-dir',"`"$root`"",'--output',"`"$Output`"",'--antigravity-smoke-test','--antigravity-executable',"`"$($desktop.FullName)`"",'--antigravity-cli-executable',"`"$cli`"") -PassThru
    if(-not $process.WaitForExit(420000)){$process.Kill();throw 'Native Antigravity smoke timed out'}
    if($process.ExitCode -ne 0){if(Test-Path (Join-Path $Output 'antigravity-smoke-error.txt')){Get-Content (Join-Path $Output 'antigravity-smoke-error.txt')};throw 'Native Antigravity smoke failed'}
    Get-Content (Join-Path $Output 'antigravity-native-result.txt')
}finally{
    if(Test-Path $root){Remove-Item $root -Recurse -Force}
    Remove-Item $scope -Recurse -Force
}
