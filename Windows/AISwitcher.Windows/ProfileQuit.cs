using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static class ProfileQuit {
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
    [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)]static extern uint RmStartSession(out uint session,uint flags,StringBuilder key);
    [DllImport("rstrtmgr.dll")]static extern uint RmRegisterResources(uint session,uint files,IntPtr names,uint count,[In]UniqueProcess[] processes,uint services,IntPtr serviceNames);
    [DllImport("rstrtmgr.dll")]static extern uint RmShutdown(uint session,uint flags,IntPtr callback);
    [DllImport("rstrtmgr.dll")]static extern uint RmEndSession(uint session);
}
