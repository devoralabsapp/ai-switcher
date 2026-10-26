using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace AISwitcher.Core;

public interface IRpcTransport : IAsyncDisposable {
    Task SendAsync(string json, CancellationToken ct);
    Task<string?> ReadAsync(CancellationToken ct);
}
public static class ChildEnvironment {
    static readonly HashSet<string> Allowed=new(new[]{"PATH","PATHEXT","SystemRoot","windir","ComSpec","USERPROFILE","HOME","HOMEDRIVE","HOMEPATH","LOCALAPPDATA","APPDATA","TEMP","TMP","TMPDIR","USERNAME","USER","LANG","LC_ALL","SSL_CERT_FILE","SSL_CERT_DIR","CODEX_CA_CERTIFICATE","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY","http_proxy","https_proxy","all_proxy","no_proxy"},StringComparer.OrdinalIgnoreCase);
    public static Dictionary<string,string> Create(IReadOnlyDictionary<string,string> inherited,string? codexHome=null) {
        var result=inherited.Where(x=>Allowed.Contains(x.Key)).ToDictionary(x=>x.Key,x=>x.Value,StringComparer.OrdinalIgnoreCase);
        if(codexHome!=null) result["CODEX_HOME"]=codexHome;
        return result;
    }
    public static ProcessStartInfo StartInfo(string executable,IEnumerable<string> arguments,IReadOnlyDictionary<string,string> environment,string directory) {
        var info=new ProcessStartInfo(executable){UseShellExecute=false,WorkingDirectory=directory,CreateNoWindow=true};
        foreach(var arg in arguments)info.ArgumentList.Add(arg);
        info.Environment.Clear();foreach(var item in environment)info.Environment[item.Key]=item.Value;
        return info;
    }
}
public sealed class StdioTransport : IRpcTransport {
    readonly Process process;
    readonly SemaphoreSlim writeLock=new(1,1);
    public StdioTransport(ProcessStartInfo info) {
        info.RedirectStandardInput=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
        info.StandardOutputEncoding=Encoding.UTF8;info.StandardErrorEncoding=Encoding.UTF8;
        process=Process.Start(info)??throw new AppError("The Codex CLI connection closed. Try again.");
        // Drain and discard raw server output: it can contain authentication URLs.
        process.ErrorDataReceived+=(_,_)=>{};process.BeginErrorReadLine();
    }
    public async Task SendAsync(string json,CancellationToken ct) {
        await writeLock.WaitAsync(ct);
        try { await process.StandardInput.WriteLineAsync(json.AsMemory(),ct);await process.StandardInput.FlushAsync(ct); }finally{writeLock.Release();}
    }
    public async Task<string?> ReadAsync(CancellationToken ct) {
        var line=await process.StandardOutput.ReadLineAsync(ct);
        if(line?.Length>8_388_608)throw new AppError("Could not read the Codex response. Update Codex CLI and try again.");
        return line;
    }
    public async ValueTask DisposeAsync() {
        process.StandardInput.Close();
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3)); }
        catch(TimeoutException) { if(!process.HasExited)process.Kill(entireProcessTree:true); }
        process.Dispose();writeLock.Dispose();
    }
}
public sealed class LocalSocketTransport : IRpcTransport {
    readonly ClientWebSocket socket=new();
    HttpMessageInvoker? invoker;
    public static async Task<LocalSocketTransport> ConnectAsync(string path,CancellationToken ct) {
        var transport=new LocalSocketTransport();
        var handler=new SocketsHttpHandler { UseProxy=false,ConnectCallback=async (_,token)=>{
            var unix=new Socket(AddressFamily.Unix,SocketType.Stream,ProtocolType.Unspecified);
            try { await unix.ConnectAsync(new UnixDomainSocketEndPoint(path),token);return new NetworkStream(unix,ownsSocket:true); }
            catch{unix.Dispose();throw;}
        }};
        transport.invoker=new HttpMessageInvoker(handler);
        try { await transport.socket.ConnectAsync(new Uri("ws://localhost/"),transport.invoker,ct);return transport; }
        catch{await transport.DisposeAsync();throw;}
    }
    public Task SendAsync(string json,CancellationToken ct)=>socket.SendAsync(Encoding.UTF8.GetBytes(json).AsMemory(),WebSocketMessageType.Text,true,ct).AsTask();
    public async Task<string?> ReadAsync(CancellationToken ct) {
        using var memory=new MemoryStream();var buffer=new byte[8192];
        while(true){var chunk=await socket.ReceiveAsync(buffer.AsMemory(),ct);if(chunk.MessageType==WebSocketMessageType.Close)return null;
            if(chunk.MessageType!=WebSocketMessageType.Text||memory.Length+chunk.Count>8_388_608)throw new AppError("Could not read the Codex response. Update Codex CLI and try again.");
            memory.Write(buffer,0,chunk.Count);if(chunk.EndOfMessage)return Encoding.UTF8.GetString(memory.ToArray());}
    }
    public ValueTask DisposeAsync(){socket.Abort();socket.Dispose();invoker?.Dispose();return ValueTask.CompletedTask;}
}
public sealed class RpcClient : IAsyncDisposable {
    readonly IRpcTransport transport;
    readonly TimeSpan timeout;
    readonly CancellationTokenSource lifetime=new();
    readonly ConcurrentDictionary<int,TaskCompletionSource<JsonElement>> pending=new();
    readonly ConcurrentDictionary<string,TaskCompletionSource<bool>> logins=new();
    readonly ConcurrentDictionary<string,bool> earlyLogins=new();
    readonly SemaphoreSlim sendLock=new(1,1);
    Task? pump;int nextId;
    public RpcClient(IRpcTransport transport,TimeSpan? timeout=null){this.transport=transport;this.timeout=timeout??TimeSpan.FromSeconds(20);}
    public async Task StartAsync(CancellationToken ct=default) {
        pump=PumpAsync();
        await RequestAsync("initialize",new{clientInfo=new{name="ai_switcher",title="AI Switcher",version="1.4.0"}},ct);
        await SendAsync(new{method="initialized"},ct);
    }
    async Task SendAsync(object message,CancellationToken ct){await sendLock.WaitAsync(ct);try{await transport.SendAsync(JsonSerializer.Serialize(message,new JsonSerializerOptions(Json.Options){WriteIndented=false}),ct);}finally{sendLock.Release();}}
    async Task<JsonElement> RequestAsync(string method,object? parameters=null,CancellationToken ct=default) {
        ct.ThrowIfCancellationRequested();var id=Interlocked.Increment(ref nextId);var completion=new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);pending[id]=completion;
        try{await SendAsync(new{id,method,@params=parameters},ct);return await completion.Task.WaitAsync(timeout,ct);}
        catch(TimeoutException){throw new AppError("Codex did not respond in time. Previously read data is not current quota. Try refreshing.");}
        finally{pending.TryRemove(id,out _);}
    }
    async Task PumpAsync(){try{
        while(!lifetime.IsCancellationRequested){var line=await transport.ReadAsync(lifetime.Token);if(line==null)break;if(string.IsNullOrWhiteSpace(line))continue;
            using var doc=JsonDocument.Parse(line);var root=doc.RootElement;
            if(root.TryGetProperty("id",out var id)&&!root.TryGetProperty("method",out _)){
                if(!id.TryGetInt32(out var integer)||!pending.TryRemove(integer,out var call))continue;
                if(root.TryGetProperty("error",out _))call.TrySetException(new AppError("Could not read Codex quota. Update Codex CLI and try again."));
                else if(root.TryGetProperty("result",out var result))call.TrySetResult(result.Clone());
                else call.TrySetException(new AppError("Could not read the Codex response. Update Codex CLI and try again."));
            }else if(root.TryGetProperty("method",out var method)&&method.GetString()=="account/login/completed"&&root.TryGetProperty("params",out var data)){
                var login=data.GetProperty("loginId").GetString()!;var success=data.GetProperty("success").GetBoolean();
                if(logins.TryRemove(login,out var waiter))waiter.TrySetResult(success);else{if(earlyLogins.Count>8)earlyLogins.Clear();earlyLogins[login]=success;}
            }else if(root.TryGetProperty("id",out var serverId))await SendAsync(new{id=serverId.Clone(),error=new{code=-32601,message="Unsupported in quota reader"}},lifetime.Token);
        }
    }catch(OperationCanceledException){}catch{ }finally{foreach(var p in pending.Values)p.TrySetException(new AppError("The Codex CLI connection closed. Try again."));foreach(var p in logins.Values)p.TrySetException(new AppError("The Codex CLI connection closed. Try again."));}}
    public async Task<Identity> ReadIdentityAsync(CancellationToken ct=default){var result=await RequestAsync("account/read",new{refreshToken=false},ct);
        if(!result.TryGetProperty("account",out var account)||account.ValueKind!=JsonValueKind.Object||Text(account,"type")!="chatgpt")throw new AppError("The Codex session is signed out or expired. Reconnect the account.");
        return new(Text(account,"email"),Text(account,"planType"),Text(account,"accountId")??Text(account,"id"));}
    static string? Text(JsonElement data,string key)=>data.TryGetProperty(key,out var value)&&value.ValueKind==JsonValueKind.String?value.GetString():null;
    public async Task<Connection> ReadQuotaAsync(CancellationToken ct=default){var before=await ReadIdentityAsync(ct);var result=await RequestAsync("account/rateLimits/read",null,ct);var limits=result.Deserialize<Limits>(Json.Options)??throw new AppError("Could not read the Codex response. Update Codex CLI and try again.");var after=await ReadIdentityAsync(ct);
        if(!before.Matches(after)||(before.AccountId!=null&&limits.AccountId!=null&&before.AccountId!=limits.AccountId))throw new AppError("The Codex account changed. Disconnect, then verify the intended account for this profile again.");
        return new(after,new(limits,DateTimeOffset.UtcNow));}
    public async Task<(string Id,Uri Url)> StartLoginAsync(CancellationToken ct=default){var result=await RequestAsync("account/login/start",new{type="chatgpt"},ct);var id=result.GetProperty("loginId").GetString()!;var url=ValidateLoginUrl(result.GetProperty("authUrl").GetString()!);return(id,url);}
    public async Task WaitForLoginAsync(string id,CancellationToken ct=default){
        var waiter=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);logins[id]=waiter;
        if(earlyLogins.TryRemove(id,out var early))waiter.TrySetResult(early);
        try{if(!await waiter.Task.WaitAsync(TimeSpan.FromMinutes(5),ct))throw new AppError("Codex sign-in did not finish. Try again or cancel the connection.");}finally{logins.TryRemove(id,out _);}}
    public Task CancelLoginAsync(string id,CancellationToken ct=default)=>RequestAsync("account/login/cancel",new{loginId=id},ct);
    public Task LogoutAsync(CancellationToken ct=default)=>RequestAsync("account/logout",null,ct);
    public static Uri ValidateLoginUrl(string value){if(!Uri.TryCreate(value,UriKind.Absolute,out var uri)||uri.Scheme!="https"||!string.IsNullOrEmpty(uri.UserInfo)||(!uri.IsDefaultPort&&uri.Port!=443)||uri.Host.ToLowerInvariant() is not ("auth.openai.com" or "chatgpt.com"))throw new AppError("Codex returned an invalid sign-in URL. The connection was stopped.");return uri;}
    public async ValueTask DisposeAsync(){lifetime.Cancel();await transport.DisposeAsync();if(pump!=null)await pump;sendLock.Dispose();lifetime.Dispose();}
}
