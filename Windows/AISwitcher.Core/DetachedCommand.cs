using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace AISwitcher.Core;

/// Native console-less launch with redirected pipes. CREATE_NO_WINDOW still
/// gives some Windows CLIs a usable CONIN$ device; DETACHED_PROCESS does not.
public sealed class DetachedCommand:IAsyncDisposable {
    int disposed;
    public Process Process { get; }
    public StreamWriter Input { get; }
    public StreamReader Output { get; }
    public StreamReader Error { get; }
    DetachedCommand(Process process,SafeFileHandle input,SafeFileHandle output,SafeFileHandle error){
        Process=process;
        Input=new(new FileStream(input,FileAccess.Write),new UTF8Encoding(false));
        Output=new(new FileStream(output,FileAccess.Read),Encoding.UTF8);
        Error=new(new FileStream(error,FileAccess.Read),Encoding.UTF8);
    }
    public static string Quote(string value){
        if(value.Contains('\0'))throw new AppError(ProviderQuota.Invalid);
        if(!value.Any(c=>char.IsWhiteSpace(c)||c=='"')&&value.Length>0)return value;
        var result=new StringBuilder("\"");var slashes=0;
        foreach(var c in value){if(c=='\\'){slashes++;continue;}result.Append('\\',c=='"'?slashes*2+1:slashes);result.Append(c);slashes=0;}
        result.Append('\\',slashes*2).Append('"');return result.ToString();
    }
    public static DetachedCommand Start(ProcessStartInfo info){
        if(!OperatingSystem.IsWindows()||info.UseShellExecute||!Path.IsPathFullyQualified(info.FileName)||info.Arguments.Length>0)throw new AppError(ProviderQuota.Invalid);
        SafeFileHandle? childInput=null,parentInput=null,parentOutput=null,childOutput=null,parentError=null,childError=null;
        IntPtr attributes=IntPtr.Zero,handles=IntPtr.Zero,environment=IntPtr.Zero;ProcessInformation native=default;Process? process=null;var resumed=false;var attributeReady=false;
        try{
            var security=new SecurityAttributes{Size=Marshal.SizeOf<SecurityAttributes>(),Inherit=true};
            if(!CreatePipe(out childInput,out parentInput,ref security,0)||!CreatePipe(out parentOutput,out childOutput,ref security,0)||!CreatePipe(out parentError,out childError,ref security,0))throw new Win32Exception();
            foreach(var pipe in new[]{parentInput,parentOutput,parentError})if(!SetHandleInformation(pipe,1,0))throw new Win32Exception();
            var length=IntPtr.Zero;_=InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref length);attributes=Marshal.AllocHGlobal(length);
            if(!InitializeProcThreadAttributeList(attributes,1,0,ref length))throw new Win32Exception();attributeReady=true;
            handles=Marshal.AllocHGlobal(IntPtr.Size*3);Marshal.WriteIntPtr(handles,childInput.DangerousGetHandle());Marshal.WriteIntPtr(handles,IntPtr.Size,childOutput.DangerousGetHandle());Marshal.WriteIntPtr(handles,IntPtr.Size*2,childError.DangerousGetHandle());
            if(!UpdateProcThreadAttribute(attributes,0,(IntPtr)0x20002,handles,(IntPtr)(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero))throw new Win32Exception();
            var startup=new StartupInfoEx{Info=new(){Size=Marshal.SizeOf<StartupInfoEx>(),Flags=0x100,Input=childInput.DangerousGetHandle(),Output=childOutput.DangerousGetHandle(),Error=childError.DangerousGetHandle()},Attributes=attributes};
            var variables=info.Environment.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase).Select(x=>x.Key+"="+x.Value);
            environment=Marshal.StringToHGlobalUni(string.Join('\0',variables)+"\0\0");
            var command=new StringBuilder(string.Join(" ",new[]{info.FileName}.Concat(info.ArgumentList).Select(Quote)));
            // Detached + suspended + Unicode env + explicit inherited-handle list.
            if(!CreateProcess(info.FileName,command,IntPtr.Zero,IntPtr.Zero,true,0x0008040c,environment,info.WorkingDirectory,ref startup,out native))throw new Win32Exception();
            process=Process.GetProcessById((int)native.Id);_=process.SafeHandle;
            var value=new DetachedCommand(process,parentInput,parentOutput,parentError);parentInput=null;parentOutput=null;parentError=null;
            if(ResumeThread(native.Thread)==uint.MaxValue){value.Input.Dispose();value.Output.Dispose();value.Error.Dispose();throw new Win32Exception();}resumed=true;
            return value;
        }finally{
            if(!resumed&&native.Process!=IntPtr.Zero){_=TerminateProcess(native.Process,1);process?.Dispose();}
            if(native.Thread!=IntPtr.Zero)CloseHandle(native.Thread);if(native.Process!=IntPtr.Zero)CloseHandle(native.Process);
            childInput?.Dispose();childOutput?.Dispose();childError?.Dispose();parentInput?.Dispose();parentOutput?.Dispose();parentError?.Dispose();
            if(attributes!=IntPtr.Zero){if(attributeReady)DeleteProcThreadAttributeList(attributes);Marshal.FreeHGlobal(attributes);}if(handles!=IntPtr.Zero)Marshal.FreeHGlobal(handles);if(environment!=IntPtr.Zero)Marshal.FreeHGlobal(environment);
        }
    }
    public async ValueTask DisposeAsync(){
        if(Interlocked.Exchange(ref disposed,1)!=0)return;
        try{Input.Dispose();if(!Process.HasExited){Process.Kill(true);await Process.WaitForExitAsync();}}
        finally{Output.Dispose();Error.Dispose();Process.Dispose();}
    }
    [StructLayout(LayoutKind.Sequential)]struct SecurityAttributes{public int Size;public IntPtr Descriptor;[MarshalAs(UnmanagedType.Bool)]public bool Inherit;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct StartupInfo{public int Size;public IntPtr Reserved,Desktop,Title;public uint X,Y,XSize,YSize,XCount,YCount,Fill,Flags;public ushort Show,ReservedSize;public IntPtr ReservedData,Input,Output,Error;}
    [StructLayout(LayoutKind.Sequential)]struct StartupInfoEx{public StartupInfo Info;public IntPtr Attributes;}
    [StructLayout(LayoutKind.Sequential)]struct ProcessInformation{public IntPtr Process,Thread;public uint Id,ThreadId;}
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool CreatePipe(out SafeFileHandle read,out SafeFileHandle write,ref SecurityAttributes security,uint size);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool SetHandleInformation(SafeFileHandle handle,uint mask,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr size);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
    [DllImport("kernel32.dll")]static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll",EntryPoint="CreateProcessW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CreateProcess(string application,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfoEx startup,out ProcessInformation process);
    [DllImport("kernel32.dll",SetLastError=true)]static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")]static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr handle);
}
