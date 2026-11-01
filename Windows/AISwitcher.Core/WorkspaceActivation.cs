using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AISwitcher.Core;

/// Ownership of the last Desktop activation, separate from authentication and history.
/// Persist across manager restarts; never infer a live backend's freshness from quota.
public static class WorkspaceActivation {
    sealed record Activation(int Version,Guid AccountId);
    static string FilePath(Repository repository,string source,string database){
        repository.CheckRoot();Repository.RejectLinks(Path.Combine(repository.Root,"WorkspaceActivations"));
        var scope=Path.GetFullPath(source).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant()+"\n"+Path.GetFullPath(database).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant();
        var key=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(scope))).ToLowerInvariant();
        var path=Path.Combine(repository.Root,"WorkspaceActivations",key+".json");Repository.RejectLinks(path);return path;
    }
    public static bool NeedsRestart(Repository repository,string source,string database,Guid accountId){
        var path=FilePath(repository,source,database);if(!File.Exists(path))return true;
        try{var previous=JsonSerializer.Deserialize<Activation>(File.ReadAllText(path));return previous==null||previous.Version!=1||previous.AccountId!=accountId;}
        catch(JsonException){throw new AppError("The local workspace paths could not be verified.");}
    }
    public static void Record(Repository repository,string source,string database,Guid accountId){
        var path=FilePath(repository,source,database);Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{File.WriteAllText(temp,JsonSerializer.Serialize(new Activation(1,accountId)));File.Move(temp,path,true);}
        finally{if(File.Exists(temp))File.Delete(temp);}
    }
    public static void Invalidate(Repository repository,string source,string database){
        var path=FilePath(repository,source,database);if(File.Exists(path))File.Delete(path);
    }
}
