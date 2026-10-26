param([ValidateSet('win-x64','win-arm64')][string]$Runtime='win-x64')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Set-Location (Join-Path $root 'Windows')
$output=Join-Path $root "Windows/artifacts/$Runtime"
dotnet publish AISwitcher.Windows/AISwitcher.Windows.csproj -c Release -r $Runtime --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false -o $output
if($LASTEXITCODE -ne 0){throw 'Windows publish failed'}
Copy-Item (Join-Path $root 'LICENSE') $output
Copy-Item (Join-Path $root 'Windows/README.md') (Join-Path $output 'README.txt')
Copy-Item (Join-Path $root 'Windows/README.vi.md') $output
$zip=Join-Path $root "Windows/artifacts/AI-Switcher-Windows-$Runtime.zip"
Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip -Force
$exe=Join-Path $root "Windows/artifacts/AI-Switcher-Windows-$Runtime.exe"
Copy-Item (Join-Path $output 'AISwitcher.exe') $exe
$exeHash=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
"$exeHash  $(Split-Path $exe -Leaf)" | Set-Content -Encoding ascii "$exe.sha256"
$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $zip -Leaf)" | Set-Content -Encoding ascii "$zip.sha256"
Write-Host "Built $zip"
