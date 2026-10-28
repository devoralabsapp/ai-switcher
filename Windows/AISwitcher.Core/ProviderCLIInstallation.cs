using System.Globalization;

namespace AISwitcher.Core;

/// User-clicked official installation in a visible PowerShell window, with a private completion marker.
public sealed class ProviderCLIInstallation {
    public const string Failed="CLI installation failed. Check the installer window, then try again.";
    public const string StillRunning="Installation is still running. Finish it in the installer window, then click Connect again.";
    public string DirectoryPath { get; }
    public string Launcher=>Path.Combine(DirectoryPath,"install.ps1");
    public string Result=>Path.Combine(DirectoryPath,"exit-status");
    public Uri InstallerUrl { get; }
    readonly Agent agent;
    public ProviderCLIInstallation(Agent agent,string root){
        if(!agent.ProviderQuota())throw new AppError("CLI installation is available for Claude and Antigravity.");
        this.agent=agent;DirectoryPath=Path.Combine(root,"Installers",Guid.NewGuid().ToString("N"));
        InstallerUrl=new(agent==Agent.Claude?"https://claude.ai/install.ps1":"https://antigravity.google/cli/install.ps1");
    }
    public string Script {
        get {
            static string Literal(string value)=>"'"+value.Replace("'","''")+"'";
            var download=Path.Combine(DirectoryPath,"official-installer.ps1");
            return $$"""
            $ErrorActionPreference='Stop'
            $aiswInstallExit=1
            try {
                Set-Location -LiteralPath {{Literal(DirectoryPath)}}
                [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
                foreach($aiswKey in @('CLAUDE_CONFIG_DIR','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','GOOGLE_API_KEY','GOOGLE_APPLICATION_CREDENTIALS','GEMINI_API_KEY','AGY_ADC_AUTH')) { Remove-Item -LiteralPath ('Env:'+ $aiswKey) -ErrorAction SilentlyContinue }
                Invoke-WebRequest -UseBasicParsing -Uri {{Literal(InstallerUrl.AbsoluteUri)}} -OutFile {{Literal(download)}} -TimeoutSec 120 -MaximumRedirection 5 -ErrorAction Stop
                & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File {{Literal(download)}}{{(agent==Agent.Claude?" latest":"")}}
                $aiswInstallExit=$LASTEXITCODE
            } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
            finally {
                [IO.File]::WriteAllText({{Literal(Result+".tmp")}},[string]$aiswInstallExit)
                Move-Item -LiteralPath {{Literal(Result+".tmp")}} -Destination {{Literal(Result)}} -Force
                if($aiswInstallExit -eq 0){Write-Host 'Installation finished. Return to AI Switcher.'}else{Write-Host {{Literal(Failed)}} -ForegroundColor Red}
            }
            """;
        }
    }
    public void Prepare(){Directory.CreateDirectory(DirectoryPath);File.WriteAllText(Launcher,Script,new System.Text.UTF8Encoding(true));}
    public async Task WaitAsync(CancellationToken ct,TimeSpan? timeout=null){
        var deadline=DateTimeOffset.UtcNow+(timeout??TimeSpan.FromMinutes(10));
        while(DateTimeOffset.UtcNow<deadline){
            ct.ThrowIfCancellationRequested();
            if(File.Exists(Result)){
                if(new FileInfo(Result).Length>32||!int.TryParse(await File.ReadAllTextAsync(Result,ct),NumberStyles.Integer,CultureInfo.InvariantCulture,out var code)||code!=0)throw new AppError(Failed);
                return;
            }
            await Task.Delay(500,ct);
        }
        throw new AppError(StillRunning);
    }
    public void CleanupIfFinished(){if(File.Exists(Result))try{Directory.Delete(DirectoryPath,true);}catch(IOException){}catch(UnauthorizedAccessException){}}
}
