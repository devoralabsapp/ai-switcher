using System;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static class ProfileQuit {
    internal static IReadOnlyList<(int Id,long Created)> ResourceUsers(string[] files){
        if(files.Length==0)return [];
        var key=new StringBuilder(33);if(RmStartSession(out var session,0,key)!=0)throw new AppError("Profile storage could not be verified.");
        try{
            if(RegisterFiles(session,(uint)files.Length,files,0,IntPtr.Zero,0,IntPtr.Zero)!=0)throw new AppError("Profile storage could not be verified.");
            uint count=0,reasons=0;var result=RmGetList(session,out var needed,ref count,null,ref reasons);
            if(result==0&&needed==0)return [];
            if(result!=234||needed>512)throw new AppError("Profile storage could not be verified.");
            count=needed;var list=new ProcessInfo[count];if(RmGetList(session,out needed,ref count,list,ref reasons)!=0)throw new AppError("Profile storage could not be verified.");
            return list.Take((int)count).Select(info=>((int)info.Process.Id,((long)(uint)info.Process.Started.dwHighDateTime<<32)|(uint)info.Process.Started.dwLowDateTime)).ToArray();
        }finally{RmEndSession(session);}
    }
    // Register a single PID plus creation time, never executable files or shared DLLs.
    // No RmForceShutdown flag: a refusing application is left running.
    public static Task RequestAsync(int pid,long created)=>Task.Run(()=>{
        var key=new StringBuilder(33);if(RmStartSession(out var session,0,key)!=0)throw new AppError("Windows could not request this profile to quit. Quit it from its own tray menu, then retry.");
        try{
            var identity=new UniqueProcess{Id=(uint)pid,Started=new(){dwLowDateTime=unchecked((int)created),dwHighDateTime=unchecked((int)(created>>32))}};
            if(RmRegisterResources(session,0,IntPtr.Zero,1,new[]{identity},0,IntPtr.Zero)!=0)throw new AppError("Windows could not request this profile to quit. Quit it from its own tray menu, then retry.");
            var result=RmShutdown(session,0,IntPtr.Zero);
            if(result!=0)throw new AppError("This profile did not agree to quit. Finish any confirmation in its window or use its own tray Quit action, then retry.");
        }finally{RmEndSession(session);}
    });
    [StructLayout(LayoutKind.Sequential)]struct UniqueProcess{public uint Id;public System.Runtime.InteropServices.ComTypes.FILETIME Started;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct ProcessInfo{public UniqueProcess Process;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string AppName;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)]public string ServiceName;public uint ApplicationType,Status,SessionId;[MarshalAs(UnmanagedType.Bool)]public bool Restartable;}
    [DllImport("rstrtmgr.dll",EntryPoint="RmRegisterResources",CharSet=CharSet.Unicode)]static extern uint RegisterFiles(uint session,uint count,[In,MarshalAs(UnmanagedType.LPArray,ArraySubType=UnmanagedType.LPWStr)]string[] files,uint applications,IntPtr processes,uint services,IntPtr serviceNames);
    [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)]static extern uint RmGetList(uint session,out uint needed,ref uint count,[In,Out]ProcessInfo[]? list,ref uint reasons);
    [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)]static extern uint RmStartSession(out uint session,uint flags,StringBuilder key);
    [DllImport("rstrtmgr.dll")]static extern uint RmRegisterResources(uint session,uint files,IntPtr names,uint count,[In]UniqueProcess[] processes,uint services,IntPtr serviceNames);
    [DllImport("rstrtmgr.dll")]static extern uint RmShutdown(uint session,uint flags,IntPtr callback);
    [DllImport("rstrtmgr.dll")]static extern uint RmEndSession(uint session);
}
