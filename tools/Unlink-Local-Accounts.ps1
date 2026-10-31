$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$source = @'
@@CS_SOURCE@@
'@
try {
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
    if ($env:AISW_UNLINK_SELF_TEST -eq '1') {
        [LocalAccountUnlink]::SelfTest()
        exit 0
    }
    Write-Host ''
    Write-Host 'AI Switcher - Unlink LOCAL project account associations' -ForegroundColor Cyan
    Write-Host 'Windows 10/11. No downloads, no admin access, no account logout.'
    Write-Host 'Project/chat IDs, messages, files and sign-in credentials are preserved.'
    Write-Host 'Cloud projects are excluded. Historical chat creator IDs are preserved.'
    Write-Host ''
    [LocalAccountUnlink]::CheckApps()
    Write-Host '1 - Inspect and remove local account associations'
    Write-Host '2 - Restore associations from a backup created by this tool'
    Write-Host 'Enter - Cancel'
    $mode = Read-Host 'Choose 1 or 2'
    if ($mode -eq '2') {
        $folder = (Read-Host 'Paste the backup folder path').Trim().Trim('"')
        if ((Read-Host 'Type RESTORE to restore original associations') -cne 'RESTORE') { exit 0 }
        [LocalAccountUnlink]::Restore($folder,$true)
        Write-Host 'Original associations restored. Conversation history was not replaced.' -ForegroundColor Green
        exit 0
    }
    if ($mode -ne '1') { Write-Host 'Cancelled. Nothing changed.'; exit 0 }
    $plan = [LocalAccountUnlink]::Discover($null)
    if ($plan.Rows.Count + $plan.Documents.Count -eq 0) {
        Write-Host 'No removable local associations found in the detected locations.'
        $extra = (Read-Host 'Optional: paste another .codex/workspace folder, or press Enter to finish').Trim().Trim('"')
        if (-not $extra) { exit 0 }
        $plan = [LocalAccountUnlink]::Discover($extra)
    }
    if ($plan.Rows.Count + $plan.Documents.Count -eq 0) { Write-Host 'No matching local associations found. Nothing changed.'; exit 0 }
    Write-Host ''
    Write-Host 'Local projects affected (the same project may appear in several profiles):' -ForegroundColor Yellow
    $plan.Projects | Sort-Object -Unique | ForEach-Object { Write-Host ('  ' + $_) }
    Write-Host ''
    Write-Host ('Project database entries: ' + $plan.Rows.Count)
    Write-Host ('Source/profile/sidebar JSON files: ' + $plan.Documents.Count)
    Write-Host 'Only the known local account-link fields are removed.'
    Write-Host 'Keep ChatGPT, Codex and AI Switcher closed until this finishes.'
    if ((Read-Host 'Type REMOVE to unlink ALL listed local projects, or Enter to cancel') -cne 'REMOVE') { Write-Host 'Cancelled. Nothing changed.'; exit 0 }
    $backup = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('AI-Switcher-Unlink-Backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    Write-Host ('Backup folder: ' + $backup)
    [void][LocalAccountUnlink]::Apply($plan,$backup,$true)
    Write-Host ''
    Write-Host 'DONE. Local project account associations were removed.' -ForegroundColor Green
    Write-Host 'Open the intended account in AI Switcher, then open the original local chat.'
    Write-Host 'To undo: run this BAT again, choose 2 and paste the backup folder.'
    Write-Host ('Backup: ' + $backup)
    exit 0
} catch {
    $errorValue = $_.Exception
    while (($errorValue -is [System.Management.Automation.MethodInvocationException] -or $errorValue -is [System.Reflection.TargetInvocationException]) -and $errorValue.InnerException) { $errorValue = $errorValue.InnerException }
    Write-Host ''
    Write-Host ('STOPPED: ' + $errorValue.Message) -ForegroundColor Red
    Write-Host 'No processes were killed. If a backup path was shown, keep that folder.'
    exit 1
}
