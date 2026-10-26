using System.Buffers.Binary;

namespace AISwitcher.Core;

/// A GUI binary named Codex.exe must never be executed as a quota CLI.
public static class WindowsExecutable {
    public static bool IsConsole(string path){
        try{
            using var file=File.OpenRead(path);Span<byte> header=stackalloc byte[64];
            if(file.Read(header)!=64||header[0]!='M'||header[1]!='Z')return false;
            var offset=BinaryPrimitives.ReadInt32LittleEndian(header[60..]);if(offset<64||offset>file.Length-96)return false;
            file.Position=offset;Span<byte> pe=stackalloc byte[96];if(file.Read(pe)!=96||!pe[..4].SequenceEqual(new byte[]{80,69,0,0}))return false;
            var magic=BinaryPrimitives.ReadUInt16LittleEndian(pe[24..]);
            return (magic is 0x10b or 0x20b)&&BinaryPrimitives.ReadUInt16LittleEndian(pe[92..])==3;
        }catch(IOException){return false;}catch(UnauthorizedAccessException){return false;}
    }
    public static bool IsStorePath(string path)=>path.Replace('\\','/').Split('/').Any(x=>x.Equals("WindowsApps",StringComparison.OrdinalIgnoreCase));
    public static bool IsCodexVersion(string output)=>System.Text.RegularExpressions.Regex.IsMatch(output.Trim(),@"^codex-cli\s+\d+\.\d+",System.Text.RegularExpressions.RegexOptions.CultureInvariant);
}
