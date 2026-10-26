using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static class CodexLocator {
    public static IEnumerable<string> UserCandidates(string local,string roaming){
        var cache=Path.Combine(local,"OpenAI","Codex","bin");
        // Versioned Desktop copies come before older unversioned/standalone CLIs.
        foreach(var folder in CacheFolders(cache))yield return Path.Combine(folder,"codex.exe");
        yield return Path.Combine(cache,"codex.exe");
        yield return Path.Combine(local,"Programs","OpenAI","Codex","bin","codex.exe");
        foreach(var package in new[]{"codex-win32-x64","codex-win32-arm64"})foreach(var triple in new[]{"x86_64-pc-windows-msvc","aarch64-pc-windows-msvc"}){
            yield return Path.Combine(roaming,"npm","node_modules","@openai","codex","node_modules","@openai",package,"vendor",triple,"codex","codex.exe");
            yield return Path.Combine(roaming,"npm","node_modules","@openai","codex","node_modules","@openai",package,"vendor",triple,"bin","codex.exe");
        }
    }
    static string[] CacheFolders(string cache){try{return Directory.Exists(cache)?Directory.EnumerateDirectories(cache).OrderByDescending(Directory.GetLastWriteTimeUtc).Take(64).ToArray():[];}catch(IOException){return [];}catch(UnauthorizedAccessException){return [];}}
    public static async Task<string?> ResolveAsync(IEnumerable<string> candidates){foreach(var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))if(await VerifyAsync(candidate))return Path.GetFullPath(candidate);return null;}
    public static async Task<bool> VerifyAsync(string path){
        if(!File.Exists(path)||WindowsExecutable.IsStorePath(path)||!WindowsExecutable.IsConsole(path))return false;
        try{
            var info=ChildEnvironment.StartInfo(path,new[]{"--version"},ChildEnvironment.Create(NativePlatform.EnvironmentValues()),Path.GetDirectoryName(path)!);
            info.RedirectStandardOutput=true;info.RedirectStandardError=true;
            using var process=Process.Start(info);if(process==null)return false;
            var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            try{await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));}catch(TimeoutException){if(!process.HasExited)process.Kill(true);return false;}
            var output=await stdout;await stderr;return process.ExitCode==0&&WindowsExecutable.IsCodexVersion(output);
        }catch(System.ComponentModel.Win32Exception){return false;}catch(IOException){return false;}catch(UnauthorizedAccessException){return false;}
    }
}
