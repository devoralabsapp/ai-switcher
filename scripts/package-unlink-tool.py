"""Build the single-file, offline Windows BAT from its reviewable sources."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
source = (root / 'tools/Unlink-Local-Accounts.cs').read_text(encoding='utf-8')
payload = (root / 'tools/Unlink-Local-Accounts.ps1').read_text(encoding='utf-8')
assert payload.count('@@CS_SOURCE@@') == 1
launcher = r'''@echo off
setlocal
set "AISW_UNLINK_SELF=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $raw=[IO.File]::ReadAllText($env:AISW_UNLINK_SELF); $parts=$raw -split '(?m)^# AISW_POWERSHELL_PAYLOAD\r?$',2; if($parts.Length -ne 2){throw 'Missing tool payload'}; & ([scriptblock]::Create($parts[1])) } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }"
set "AISW_UNLINK_EXIT=%ERRORLEVEL%"
echo.
if not "%AISW_UNLINK_SELF_TEST%"=="1" pause
exit /b %AISW_UNLINK_EXIT%
# AISW_POWERSHELL_PAYLOAD
'''
result = launcher + payload.replace('@@CS_SOURCE@@', source)
(root / 'tools/Unlink-Local-Accounts.bat').write_bytes(result.replace('\r\n','\n').replace('\n','\r\n').encode('utf-8'))
print('Built tools/Unlink-Local-Accounts.bat (offline, self-contained).')
