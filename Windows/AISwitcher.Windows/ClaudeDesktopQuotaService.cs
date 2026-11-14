using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;

internal sealed class ClaudeDesktopQuotaService {
    readonly Repository repo;
    readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect=false,UseCookies=false }){Timeout=TimeSpan.FromSeconds(20)};
    public ClaudeDesktopQuotaService(Repository repository){repo=repository;}
    sealed record Row(string Name,string Host,string Value,byte[] Encrypted,long Expires,bool HostDigest);
    sealed class Session(string token,string? organization,byte[] fingerprint){
        public string? Organization=>organization;
        public byte[] Fingerprint=>fingerprint;
        public HttpRequestMessage Request(string path){
            var usage=path.StartsWith("/api/organizations/",StringComparison.Ordinal)&&path.EndsWith("/usage",StringComparison.Ordinal)&&Guid.TryParse(path["/api/organizations/".Length..^"/usage".Length],out _);
            if(path!="/api/account"&&path!="/api/organizations"&&!usage)throw new AppError(ProviderQuota.Invalid);
            var request=new HttpRequestMessage(HttpMethod.Get,"https://claude.ai"+path);
            request.Headers.Add("Cookie","sessionKey="+token);request.Headers.Add("Accept","application/json");request.Headers.Add("Origin","https://claude.ai");request.Headers.Referrer=new Uri("https://claude.ai/settings/usage");return request;
        }
        public override string ToString()=>"Claude Desktop session (redacted)";
    }
    static void CheckPath(string file){for(var current=Path.GetFullPath(file);!string.IsNullOrEmpty(current);current=Path.GetDirectoryName(current))Repository.RejectLinks(current);}
    List<Row> Rows(Account a){
        var home=repo.DataPath(a);var file=new[]{Path.Combine(home,"Network","Cookies"),Path.Combine(home,"Cookies")}.FirstOrDefault(File.Exists)??throw new AppError(ClaudeDesktopAccount.SignedOut);
        foreach(var suffix in new[]{"","-wal","-shm"})CheckPath(file+suffix);
        IntPtr db=IntPtr.Zero,statement=IntPtr.Zero,meta=IntPtr.Zero;
        try{
            if(Open(file,out db,1|0x01000000,IntPtr.Zero)!=0)throw new AppError(ClaudeDesktopAccount.Unavailable);BusyTimeout(db,500);
            var version=0;if(Prepare(db,"SELECT value FROM meta WHERE key='version'",-1,out meta,IntPtr.Zero)==0&&Step(meta)==100)version=ColumnInt(meta,0);
            const string sql="SELECT name,host_key,value,encrypted_value,expires_utc FROM cookies WHERE host_key IN ('.claude.ai','claude.ai') AND name IN ('sessionKey','lastActiveOrg') AND path='/' ORDER BY host_key,name LIMIT 8";
            if(Prepare(db,sql,-1,out statement,IntPtr.Zero)!=0)throw new AppError(ClaudeDesktopAccount.Unavailable);
            List<Row> rows=[];
            while(true){var status=Step(statement);if(status==101)break;if(status!=100)throw new AppError(ClaudeDesktopAccount.Unavailable);
                string Text(int column){if(ColumnBytes(statement,column)>8192)throw new AppError(ProviderQuota.Invalid);return Marshal.PtrToStringUTF8(ColumnText(statement,column))??"";}
                var count=ColumnBytes(statement,3);if(count<0||count>8192)throw new AppError(ProviderQuota.Invalid);var data=new byte[count];if(count>0)Marshal.Copy(ColumnBlob(statement,3),data,0,count);
                rows.Add(new(Text(0),Text(1),Text(2),data,ColumnInt64(statement,4),version>=24));
            }return rows;
        }finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);if(meta!=IntPtr.Zero)FinalizeStatement(meta);if(db!=IntPtr.Zero)Close(db);}
    }
    static byte[] Fingerprint(List<Row> rows){using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);foreach(var row in rows)foreach(var data in new[]{Encoding.UTF8.GetBytes(row.Name),Encoding.UTF8.GetBytes(row.Host),Encoding.UTF8.GetBytes(row.Value),row.Encrypted,Encoding.UTF8.GetBytes(row.Expires.ToString(System.Globalization.CultureInfo.InvariantCulture))}){hash.AppendData(Encoding.UTF8.GetBytes(data.Length.ToString(System.Globalization.CultureInfo.InvariantCulture)));hash.AppendData(new byte[]{0});hash.AppendData(data);}return hash.GetHashAndReset();}
    public bool HasSession(Account a){try{repo.ValidateOwned(repo.ProfilePath(a),a.Id);return Rows(a).Any(row=>row.Name=="sessionKey"&&(row.Value.Length>0||row.Encrypted.Length>0));}catch{return false;}}
    Session ReadSession(Account a){
        repo.ValidateOwned(repo.ProfilePath(a),a.Id);var rows=Rows(a);byte[]? key=null;
        try{
            string Decode(Row row){if(row.Value.Length>0&&row.Encrypted.Length==0)return row.Value;
                var data=row.Encrypted;if(data.Length<3)throw new AppError(ClaudeDesktopAccount.Encryption);byte[] plain;
                if(data.AsSpan(0,3).SequenceEqual("v10"u8)){
                    if(key==null){var state=Path.Combine(repo.DataPath(a),"Local State");CheckPath(state);if(!File.Exists(state)||new FileInfo(state).Length>1048576)throw new AppError(ClaudeDesktopAccount.Encryption);
                        using var doc=JsonDocument.Parse(File.ReadAllText(state));var encoded=Convert.FromBase64String(doc.RootElement.GetProperty("os_crypt").GetProperty("encrypted_key").GetString()!);
                        if(encoded.Length<6||!encoded.AsSpan(0,5).SequenceEqual("DPAPI"u8))throw new AppError(ClaudeDesktopAccount.Encryption);key=Unprotect(encoded[5..]);}
                    return ClaudeDesktopAccount.DecryptCookie(data,key,row.Host,row.HostDigest);
                } else if(data.AsSpan(0,3).SequenceEqual("v20"u8)) throw new AppError(ClaudeDesktopAccount.Encryption);
                else plain=Unprotect(data);
                try { return ClaudeDesktopAccount.CookieText(plain,row.Host,row.HostDigest); }
                finally { CryptographicOperations.ZeroMemory(plain); }
            }
            var now=(DateTimeOffset.UtcNow.ToUnixTimeSeconds()+11644473600L)*1000000;
            var valid=rows.Where(row=>row.Expires==0||row.Expires>now).ToArray();
            var sessions=valid.Where(row=>row.Name=="sessionKey"&&(row.Value.Length>0||row.Encrypted.Length>0)).Select(Decode).ToArray();var token=sessions.FirstOrDefault()??throw new AppError(ClaudeDesktopAccount.SignedOut);
            if(token.Length==0||token.Length>8192||sessions.Any(x=>x!=token)||token.Any(c=>c<=32||c>=127||c==';'||c==','))throw new AppError(ProviderQuota.Changed);
            var orgs=valid.Where(row=>row.Name=="lastActiveOrg").Select(Decode).Where(x=>Guid.TryParse(x,out _)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            return new(token,orgs.Length==1?orgs[0]:null,Fingerprint(rows));
        }catch(AppError){throw;}catch(Exception error)when(error is CryptographicException or JsonException or FormatException or KeyNotFoundException or DecoderFallbackException){throw new AppError(ClaudeDesktopAccount.Encryption);}
        finally{if(key!=null)CryptographicOperations.ZeroMemory(key);}
    }
    public async Task<Connection> ReadAsync(Account a,CancellationToken ct){
        var session=await Task.Run(()=>ReadSession(a),ct);
        async Task<JsonDocument> Read(string path){using var request=session.Request(path);using var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);
            if(response.StatusCode==System.Net.HttpStatusCode.Unauthorized)throw new AppError(ClaudeDesktopAccount.SignedOut);if(!response.IsSuccessStatusCode)throw new AppError(ClaudeDesktopAccount.Unavailable);
            if(response.Content.Headers.ContentLength>262144)throw new AppError(ProviderQuota.Invalid);
            await using var input=await response.Content.ReadAsStreamAsync(ct);using var output=new MemoryStream();var buffer=new byte[8192];int count;while((count=await input.ReadAsync(buffer,ct))>0){if(output.Length+count>262144)throw new AppError(ProviderQuota.Invalid);output.Write(buffer,0,count);}return JsonDocument.Parse(output.ToArray());}
        using var account=await Read("/api/account");using var orgs=await Read("/api/organizations");
        var metadata=ClaudeDesktopAccount.Parse(account.RootElement,orgs.RootElement,session.Organization,a.EmailHint);QuotaSnapshot? quota=null;
        if(metadata.Organization!=null)try{using var usage=await Read("/api/organizations/"+metadata.Organization+"/usage");quota=ClaudeDesktopAccount.Usage(usage.RootElement,metadata.Identity).Quota;}catch(AppError error)when(error.Key!=ClaudeDesktopAccount.SignedOut){}
        using var after=await Read("/api/account");var verified=ClaudeDesktopAccount.Parse(after.RootElement,orgs.RootElement,session.Organization,a.EmailHint);
        if(!metadata.Identity.Matches(verified.Identity)||metadata.Identity.PlanType!=verified.Identity.PlanType||!CryptographicOperations.FixedTimeEquals(session.Fingerprint,Fingerprint(Rows(a))))throw new AppError(ProviderQuota.Changed);
        ct.ThrowIfCancellationRequested();repo.ValidateOwned(repo.ProfilePath(a),a.Id);var scoped=verified.Identity with{AccountId="claudeDesktop:"+verified.Identity.AccountId+":"+(metadata.Organization??"unknown")};return new(scoped,quota,DateTimeOffset.UtcNow,"claudeDesktop");
    }
    [StructLayout(LayoutKind.Sequential)]struct Blob{public int Length;public IntPtr Data;}
    static byte[] Unprotect(byte[] encrypted){var input=new Blob{Length=encrypted.Length,Data=Marshal.AllocHGlobal(encrypted.Length)};try{Marshal.Copy(encrypted,0,input.Data,encrypted.Length);if(!CryptUnprotectData(ref input,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,1,out var output))throw new AppError(ClaudeDesktopAccount.Encryption);try{if(output.Length<=0||output.Length>8192)throw new AppError(ClaudeDesktopAccount.Encryption);var value=new byte[output.Length];Marshal.Copy(output.Data,value,0,value.Length);return value;}finally{LocalFree(output.Data);}}finally{Marshal.FreeHGlobal(input.Data);}}
    [DllImport("crypt32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]static extern bool CryptUnprotectData(ref Blob input,IntPtr description,IntPtr entropy,IntPtr reserved,IntPtr prompt,int flags,out Blob output);
    [DllImport("kernel32.dll")]static extern IntPtr LocalFree(IntPtr pointer);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_open_v2",CallingConvention=CallingConvention.Cdecl)]static extern int Open([MarshalAs(UnmanagedType.LPUTF8Str)]string file,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_close",CallingConvention=CallingConvention.Cdecl)]static extern int Close(IntPtr db);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_busy_timeout",CallingConvention=CallingConvention.Cdecl)]static extern int BusyTimeout(IntPtr db,int ms);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_prepare_v2",CallingConvention=CallingConvention.Cdecl)]static extern int Prepare(IntPtr db,[MarshalAs(UnmanagedType.LPUTF8Str)]string sql,int size,out IntPtr statement,IntPtr tail);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_step",CallingConvention=CallingConvention.Cdecl)]static extern int Step(IntPtr statement);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_text",CallingConvention=CallingConvention.Cdecl)]static extern IntPtr ColumnText(IntPtr statement,int column);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_blob",CallingConvention=CallingConvention.Cdecl)]static extern IntPtr ColumnBlob(IntPtr statement,int column);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_bytes",CallingConvention=CallingConvention.Cdecl)]static extern int ColumnBytes(IntPtr statement,int column);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_int",CallingConvention=CallingConvention.Cdecl)]static extern int ColumnInt(IntPtr statement,int column);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_int64",CallingConvention=CallingConvention.Cdecl)]static extern long ColumnInt64(IntPtr statement,int column);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_finalize",CallingConvention=CallingConvention.Cdecl)]static extern int FinalizeStatement(IntPtr statement);
}
