using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AISwitcher.Core;

/// Copies program files only; the caller must establish the installed package source.
/// Streaming creates ordinary destination files instead of retaining MSIX/EFS attributes.
public static class StoreRuntime {
    static readonly ConcurrentDictionary<string,SemaphoreSlim> Gates=new(StringComparer.OrdinalIgnoreCase);
    sealed record Manifest(string Root,string Source,string Executable,Dictionary<string,string> Hashes);
    const string Marker="ai-switcher-runtime.json";
    static string ProviderFor(string source)=>Path.GetFileName(source).Equals("Claude.exe",StringComparison.OrdinalIgnoreCase)?"claude":"chatgpt";
    static string ProviderFor(Agent agent)=>agent switch{Agent.Chatgpt=>"chatgpt",Agent.Claude=>"claude",_=>throw new ArgumentOutOfRangeException(nameof(agent))};
    public static string DirectoryFor(string root,string source){var key=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(source).ToUpperInvariant()))).ToLowerInvariant()[..24];return Path.Combine(Path.GetFullPath(root),"Runtimes",ProviderFor(source),key);}
    public static string ExecutableFor(string root,string source)=>Path.Combine(DirectoryFor(root,source),Path.GetFileName(source));
    static void Ensure(string path){Repository.RejectLinks(path);Directory.CreateDirectory(path);Repository.RejectLinks(path);}
    static Manifest ReadMarker(string root,string directory){Repository.RejectLinks(directory);var path=Path.Combine(directory,Marker);Repository.RejectLinks(path);var value=JsonSerializer.Deserialize<Manifest>(File.ReadAllText(path),Json.Options)??throw new IOException("Invalid runtime marker");if(!string.Equals(value.Root,Path.GetFullPath(root),StringComparison.OrdinalIgnoreCase)||!string.Equals(DirectoryFor(root,value.Source),directory,StringComparison.OrdinalIgnoreCase)||Path.GetFileName(value.Executable)!=value.Executable)throw new IOException("Runtime ownership mismatch");return value;}
    public static bool IsManagedExecutable(string root,string executable,Agent agent=Agent.Chatgpt){try{var parent=Path.GetDirectoryName(Path.GetFullPath(executable))!;if(!parent.StartsWith(Path.Combine(Path.GetFullPath(root),"Runtimes",ProviderFor(agent))+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))return false;var marker=ReadMarker(root,parent);return ProviderFor(marker.Source)==ProviderFor(agent)&&string.Equals(marker.Executable,Path.GetFileName(executable),StringComparison.OrdinalIgnoreCase);}catch(IOException){return false;}catch(UnauthorizedAccessException){return false;}catch(JsonException){return false;}}
    public static async Task<string> PrepareAsync(string root,string source,CancellationToken ct=default){
        source=Path.GetFullPath(source);root=Path.GetFullPath(root);var destination=DirectoryFor(root,source);var gate=Gates.GetOrAdd(destination,_=>new(1,1));await gate.WaitAsync(ct);
        string? staging=null;
        try{
            Repository.RejectLinks(root);Ensure(root);Ensure(Path.Combine(root,"Runtimes"));Ensure(Path.Combine(root,"Runtimes",ProviderFor(source)));
            var program=Path.GetDirectoryName(source)!;Repository.RejectLinks(program);Repository.RejectLinks(source);
            if(!File.Exists(source)||!File.Exists(Path.Combine(program,"resources","app.asar")))throw new IOException("Missing installed program files");
            if(Directory.Exists(destination)){
                var marker=ReadMarker(root,destination);if(!string.Equals(marker.Source,source,StringComparison.OrdinalIgnoreCase))throw new IOException("Runtime source mismatch");
                foreach(var name in new[]{Path.GetFileName(source),Path.Combine("resources","app.asar")}){var path=Path.Combine(destination,name);Repository.RejectLinks(Path.GetDirectoryName(path)!);Repository.RejectLinks(path);using var file=File.OpenRead(path);var hash=Convert.ToHexString(await SHA256.HashDataAsync(file,ct));if(!marker.Hashes.TryGetValue(name,out var expected)||expected!=hash)throw new IOException("Runtime integrity check failed");}
                return Path.Combine(destination,marker.Executable);
            }
            Repository.RejectLinks(destination);staging=Path.Combine(Path.GetDirectoryName(destination)!,".preparing-"+Guid.NewGuid().ToString("N"));Ensure(staging);
            var hashes=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);long bytes=0;int count=0;
            async Task Copy(string from,string to){
                Repository.RejectLinks(from);Ensure(to);
                foreach(var entry in Directory.EnumerateFileSystemEntries(from)){
                    ct.ThrowIfCancellationRequested();Repository.RejectLinks(entry);var target=Path.Combine(to,Path.GetFileName(entry));
                    if(Directory.Exists(entry)){await Copy(entry,target);continue;}
                    var length=new FileInfo(entry).Length;bytes+=length;if(bytes>16L*1024*1024*1024||++count>100000)throw new IOException("Unexpected runtime size");
                    using var input=new FileStream(entry,FileMode.Open,FileAccess.Read,FileShare.Read,131072,true);
                    await using var output=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None,131072,true);
                    using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);var buffer=new byte[131072];int read;
                    while((read=await input.ReadAsync(buffer,ct))>0){hash.AppendData(buffer,0,read);await output.WriteAsync(buffer.AsMemory(0,read),ct);}await output.FlushAsync(ct);
                    hashes.Add(Path.GetRelativePath(program,entry),Convert.ToHexString(hash.GetHashAndReset()));
                }
            }
            await Copy(program,staging);
            await File.WriteAllTextAsync(Path.Combine(staging,Marker),JsonSerializer.Serialize(new Manifest(root,source,Path.GetFileName(source),hashes),Json.Options),ct);
            Directory.Move(staging,destination);staging=null;return Path.Combine(destination,Path.GetFileName(source));
        }finally{if(staging!=null&&Directory.Exists(staging))Repository.DeleteTree(staging);gate.Release();}
    }
}
