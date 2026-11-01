using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal sealed class AntigravityDesktopService(Repository repo,NativePlatform platform) {
    sealed class Background(Process process,string csrf){
        public Process Process=process;public string Csrf=csrf;public StringBuilder Startup=new();public bool PrivateStore;
        public int? Port {get{lock(Startup){var matches=Regex.Matches(Startup.ToString(),@"listening on random port at (\d+) for HTTP\b");return matches.Count>0?int.Parse(matches[^1].Groups[1].Value):null;}}}
    }
    sealed record Endpoint(int Root,long RootCreated,int Pid,long Created,int Port,string Csrf,string Executable,bool Tls=false);
    readonly Dictionary<Guid,Background> backgrounds=[];
    internal Action<string>? FixtureDiagnostic { get; set; }
    readonly Dictionary<Guid,Endpoint> endpoints=[];
    internal int? BackendPid(Account account)=>backgrounds.TryGetValue(account.Id,out var backend)&&!backend.Process.HasExited?backend.Process.Id:null;
    public bool IsActive(Account account)=>backgrounds.TryGetValue(account.Id,out var value)&&!value.Process.HasExited;
    static string? Argument(string[] args,string key){var direct=args.FirstOrDefault(x=>x.StartsWith(key+"=",StringComparison.Ordinal));if(direct!=null)return direct[(key.Length+1)..];var index=Array.IndexOf(args,key);return index>=0&&index+1<args.Length?args[index+1]:null;}
    public async Task ConnectAsync(Account account,CancellationToken ct){
        AntigravityProfile.Validate(repo,account);await platform.RefreshProcessesAsync();if(platform.Owned(account)!=null||IsActive(account))return;
        if(backgrounds.ContainsKey(account.Id))await StopAsync(account);
        if(platform.HasOwnedProcesses(account))throw new AppError("Close this Antigravity account session once, then open it again to apply separate sign-in storage. Your data is kept.");
        repo.PrepareProfile(account);foreach(var dir in AntigravityProfile.Directories(repo,account))NativePlatform.ProtectDirectory(dir);
        var app=await platform.FindExecutableAsync("antigravity")??throw new AppError("The required app or browser was not found. Choose its executable in Settings.");var native=NativePlatform.AntigravityServerPath(app);
        if(!AntigravityProfile.SupportsPrivateStorage(native))throw new AppError(AntigravityProfile.Unsupported);
        var csrf=Guid.NewGuid().ToString();var version=FileVersionInfo.GetVersionInfo(app).ProductVersion??"2";
        var args=new[]{"--standalone","--override_ide_name","antigravity","--subclient_type","hub","--override_ide_version",version,"--override_user_agent_name","antigravity","--http_server_port","0","--csrf_token",csrf,"--app_data_dir","antigravity","--api_server_url","https://generativelanguage.googleapis.com","--cloud_code_endpoint","https://daily-cloudcode-pa.googleapis.com","--exit_on_stdin_close"};
        // Windows' browser launcher inherits the current directory and can keep
        // it locked after OAuth cancellation. Keep CWD outside account storage;
        // the explicit private environment still controls every native auth path.
        var info=ChildEnvironment.StartInfo(native,args,AntigravityProfile.Environment(NativePlatform.EnvironmentValues(),repo,account),Environment.GetFolderPath(Environment.SpecialFolder.System));
        info.RedirectStandardInput=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
        var process=new Process{StartInfo=info};var backend=new Background(process,csrf);
        void Output(object sender,DataReceivedEventArgs e){if(e.Data==null)return;if(FixtureDiagnostic!=null){if(e.Data.Contains("file-based token storage"))FixtureDiagnostic("native file storage: "+(e.Data.Contains("WSL environment")?"WSL":"other"));if(e.Data.Contains("listening"))FixtureDiagnostic("native listener startup");if(e.Data.Contains("Unknown command line flag"))FixtureDiagnostic("unsupported native flag");}lock(backend.Startup){if(e.Data.Contains("Using file-based token storage because WSL environment detected",StringComparison.Ordinal))backend.PrivateStore=true;if(backend.Startup.Length<65536)backend.Startup.AppendLine(e.Data[..Math.Min(e.Data.Length,65536-backend.Startup.Length)]);}}
        process.OutputDataReceived+=Output;process.ErrorDataReceived+=Output;
        try{
            process.Start();backgrounds[account.Id]=backend;process.BeginOutputReadLine();process.BeginErrorReadLine();
            for(var i=0;i<100;i++){
                ct.ThrowIfCancellationRequested();if(process.HasExited){FixtureDiagnostic?.Invoke("native exited: "+process.ExitCode);throw new AppError(AntigravityProfile.Unsupported);}
                if(backend.Port!=null&&backend.PrivateStore)return;
                await Task.Delay(200,ct);
            }
            throw new AppError("The provider quota request timed out. Try again.");
        }catch{await StopAsync(account);if(!backgrounds.ContainsKey(account.Id))process.Dispose();throw;}
    }
    public async Task StopAsync(Account account){
        endpoints.Remove(account.Id);if(!backgrounds.Remove(account.Id,out var backend))return;
        var process=backend.Process;
        try{if(!process.HasExited){process.StandardInput.Close();try{await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3));}catch(TimeoutException){if(!process.HasExited)process.Kill(true);await process.WaitForExitAsync();}}}
        finally{process.Dispose();}
    }
    public async Task StopAllAsync(){foreach(var id in backgrounds.Keys.ToArray())await StopAsync(new Account{Id=id});}
    readonly ConcurrentDictionary<(int Pid,long Created,int Port),string> certificatePins=new();
    HttpClient Client(Endpoint endpoint,TimeSpan timeout){
        var handler=new SocketsHttpHandler{UseProxy=false,AllowAutoRedirect=false,UseCookies=false,Credentials=null,ConnectTimeout=TimeSpan.FromSeconds(3)};
        if(endpoint.Tls)handler.SslOptions.RemoteCertificateValidationCallback=(_,certificate,_,_)=>{
            // Hub supplies a self-signed localhost certificate. Trust only this
            // verified native PID + start time + listening port, then pin its cert.
            // This handler is used solely for a fixed 127.0.0.1 URI; no redirects,
            // proxies, remote origins or caller-selected endpoints are accepted.
            if(certificate==null||!Valid(endpoint))return false;
            var hash=certificate.GetCertHashString(HashAlgorithmName.SHA256);
            return certificatePins.GetOrAdd((endpoint.Pid,endpoint.Created,endpoint.Port),hash)==hash;
        };
        return new HttpClient(handler){Timeout=timeout};
    }
    static bool SameProcess(int id,long created,string? executable=null){try{using var p=Process.GetProcessById(id);return !p.HasExited&&p.StartTime.ToUniversalTime().ToFileTimeUtc()==created&&(executable==null||NativePlatform.SamePath(p.MainModule!.FileName!,executable));}catch(ArgumentException){return false;}catch(System.ComponentModel.Win32Exception){return false;}}
    bool Valid(Endpoint endpoint)=>SameProcess(endpoint.Root,endpoint.RootCreated)&&SameProcess(endpoint.Pid,endpoint.Created,endpoint.Executable)&&ListeningPorts(endpoint.Pid).Contains(endpoint.Port);
    async Task<JsonElement> Send(Endpoint endpoint,string method,CancellationToken ct,bool discovery=false){
        if(method is not ("GetUserStatus" or "RetrieveUserQuotaSummary" or "Login")||!Valid(endpoint))throw new AppError(ProviderQuota.Changed);
        using var client=Client(endpoint,TimeSpan.FromSeconds(discovery?5:method=="Login"?600:20));
        using var request=new HttpRequestMessage(HttpMethod.Post,$"{(endpoint.Tls?"https":"http")}://127.0.0.1:{endpoint.Port}/exa.language_server_pb.LanguageServerService/{method}");request.Content=new StringContent("{}",Encoding.UTF8,"application/json");request.Headers.Add("Connect-Protocol-Version","1");request.Headers.Add("X-Codeium-Csrf-Token",endpoint.Csrf);
        using var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);using var stream=await response.Content.ReadAsStreamAsync(ct);using var memory=new MemoryStream();var buffer=new byte[8192];int size;
        while((size=await stream.ReadAsync(buffer,ct))>0){if(memory.Length+size>1048576)throw new AppError(ProviderQuota.Invalid);memory.Write(buffer,0,size);}
        if(!Valid(endpoint))throw new AppError(ProviderQuota.Changed);
        if(response.StatusCode is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden)throw new AppError(ProviderQuota.SignedOut);
        if(!response.IsSuccessStatusCode)throw new AppError(ProviderQuota.Unavailable);
        try{using var doc=JsonDocument.Parse(memory.ToArray());return doc.RootElement.Clone();}catch(JsonException){throw new AppError(ProviderQuota.Invalid);}
    }
    async Task<Endpoint> Ready(Account account,CancellationToken ct){
        AntigravityProfile.Validate(repo,account);if(endpoints.TryGetValue(account.Id,out var cached)&&Valid(cached))return cached;
        for(var attempt=0;attempt<60;attempt++){
            ct.ThrowIfCancellationRequested();Endpoint? candidate=null;
            if(backgrounds.TryGetValue(account.Id,out var background)&&!background.Process.HasExited&&background.Port is {} port){
                using var current=Process.GetCurrentProcess();candidate=new(current.Id,current.StartTime.ToUniversalTime().ToFileTimeUtc(),background.Process.Id,background.Process.StartTime.ToUniversalTime().ToFileTimeUtc(),port,background.Csrf,background.Process.StartInfo.FileName);
            }else{
                await platform.RefreshProcessesAsync();var root=platform.Owned(account);
                if(attempt==0||attempt==59)FixtureDiagnostic?.Invoke("Desktop root: "+(root==null?"missing":"present"));
                if(root!=null){
                    if(!root.Arguments.Contains(AntigravityProfile.MarkerArgument))throw new AppError("Close this Antigravity account session once, then open it again to apply separate sign-in storage. Your data is kept.");
                    var app=await platform.FindExecutableAsync("antigravity");if(app==null)throw new AppError(AntigravityProfile.Unsupported);
                    var native=NativePlatform.AntigravityServerPath(app);var owned=platform.SessionProcesses(account);var children=owned.Where(p=>NativePlatform.SamePath(p.Executable,native)).ToArray();
                    if(attempt==0||attempt==59){FixtureDiagnostic?.Invoke("Desktop native candidates: "+children.Length+"; session runtimes: "+owned.Count);foreach(var child in platform.Processes.Where(p=>p.ParentId==root.Id))FixtureDiagnostic?.Invoke("Direct child executable: "+Path.GetFileName(child.Executable));foreach(var child in children)FixtureDiagnostic?.Invoke("Candidate csrf flag: "+(Argument(child.Arguments,"--csrf_token")!=null)+"; listener count: "+ListeningPorts(child.Id).Count);}
                    if(children.Length==1){var child=children[0];var csrf=Argument(child.Arguments,"--csrf_token");if(csrf is {Length:>0 and <=256}&&!csrf.Any(char.IsControl)){
                        foreach(var listening in ListeningPorts(child.Id)){
                            foreach(var tls in child.Arguments.Contains("--https_server_port")?new[]{true,false}:new[]{false,true}){
                                var value=new Endpoint(root.Id,root.Created,child.Id,child.Created,listening,csrf,native,tls);
                                try{await Send(value,"GetUserStatus",ct,true);candidate=value;break;}catch(AppError error)when(error.Key==ProviderQuota.SignedOut){candidate=value;break;}catch(Exception error)when(error is HttpRequestException or TaskCanceledException or JsonException||error is AppError){ct.ThrowIfCancellationRequested();if(attempt==0||attempt==59)FixtureDiagnostic?.Invoke("Native status probe "+(tls?"TLS":"HTTP")+": "+(error is AppError appError?appError.Key:error.GetType().Name));}
                            }
                            if(candidate!=null)break;
                        }
                    }}
                }else if(!IsActive(account))throw new AppError(ProviderQuota.Unavailable);
            }
            if(candidate!=null&&Valid(candidate)){endpoints[account.Id]=candidate;return candidate;}
            await Task.Delay(250,ct);
        }
        throw new AppError(ProviderQuota.Unavailable);
    }
    public async Task<Connection> ReadAsync(Account account,CancellationToken ct){
        var endpoint=await Ready(account,ct);var saved=AntigravityProfile.ReadIdentity(AntigravityProfile.DesktopIdentity(repo,account));
        var before=await Send(endpoint,"GetUserStatus",ct);_=AntigravityProfile.Status(before);
        var quota=await Send(endpoint,"RetrieveUserQuotaSummary",ct);var after=await Send(endpoint,"GetUserStatus",ct);
        var connection=AntigravityProfile.Parse(before,quota,after,account.EmailHint);var savedAfter=AntigravityProfile.ReadIdentity(AntigravityProfile.DesktopIdentity(repo,account));
        if(saved!=savedAfter||savedAfter?.Email is {} email&&!string.Equals(email,connection.Identity.Email,StringComparison.OrdinalIgnoreCase))throw new AppError(ProviderQuota.Changed);
        return connection;
    }
    public async Task SignInAsync(Account account,CancellationToken ct){var endpoint=await Ready(account,ct);_=await Send(endpoint,"Login",ct);}

    internal static HashSet<int> ListeningPorts(int pid){
        var result=new HashSet<int>();foreach(var family in new[]{2,23}){
            var length=0;_=GetExtendedTcpTable(IntPtr.Zero,ref length,false,family,5,0);if(length<4||length>16777216)throw new AppError(ProviderQuota.Invalid);
            var table=Marshal.AllocHGlobal(length);try{
                if(GetExtendedTcpTable(table,ref length,false,family,5,0)!=0)throw new AppError(ProviderQuota.Unavailable);
                var count=Marshal.ReadInt32(table);var rowSize=family==2?24:56;var portOffset=family==2?8:20;var pidOffset=family==2?20:52;var stateOffset=family==2?0:48;
                if(count<0||count>(length-4)/rowSize)throw new AppError(ProviderQuota.Invalid);
                for(var i=0;i<count;i++){var row=IntPtr.Add(table,4+i*rowSize);if(Marshal.ReadInt32(row,pidOffset)==pid&&Marshal.ReadInt32(row,stateOffset)==2){var port=Marshal.ReadByte(row,portOffset)*256+Marshal.ReadByte(row,portOffset+1);if(port>=1024)result.Add(port);}}
            }finally{Marshal.FreeHGlobal(table);}
        }return result;
    }
    [DllImport("iphlpapi.dll")]static extern uint GetExtendedTcpTable(IntPtr table,ref int length,bool order,int family,int tableClass,uint reserved);
}
