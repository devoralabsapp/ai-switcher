using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using AISwitcher.Core;

namespace AISwitcher.Windows;
/// Uses Windows' SQLite library and an ordinary transaction; never copies live DB/WAL files.
internal static class WorkspaceIndex {
    public static bool ContainsHistory(string home){
        foreach(var path in Directory.EnumerateFiles(home,"state_*.sqlite")){Repository.RejectLinks(path);IntPtr db=IntPtr.Zero;IntPtr statement=IntPtr.Zero;
            try{if(Open(path,out db,1,IntPtr.Zero)!=0||Prepare(db,"SELECT EXISTS(SELECT 1 FROM threads LIMIT 1)",-1,out statement,IntPtr.Zero)!=0)throw new AppError("The shared workspace database could not be updated. Its data was preserved.");if(Step(statement)!=100)throw new AppError("The shared workspace database could not be updated. Its data was preserved.");if(ColumnInt(statement,0)!=0)return true;}
            finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);if(db!=IntPtr.Zero)Close(db);}
        }
        return false;
    }
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_int",CallingConvention=CallingConvention.Cdecl)]static extern int ColumnInt(IntPtr statement,int column);
    public static void Canonicalize(string databaseHome,string profileHome,string source){
        Repository.RejectLinks(databaseHome);
        foreach(var path in Directory.EnumerateFiles(databaseHome,"*.sqlite")){
            Repository.RejectLinks(path);IntPtr db=IntPtr.Zero;
            try{
                if(Open(path,out db,2,IntPtr.Zero)!=0)throw new AppError("The shared workspace database could not be updated. Its data was preserved.");BusyTimeout(db,5000);
                if(!HasRolloutColumn(db))continue;
                if(Exec(db,"BEGIN IMMEDIATE",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)throw new AppError("The shared workspace database could not be updated. Its data was preserved.");
                try{foreach(var name in new[]{"sessions","archived_sessions"})foreach(var separator in new[]{'\\','/'}){
                    var old=Path.Combine(profileHome,name).Replace('\\',separator)+separator;var target=Path.Combine(source,name).Replace('\\',separator)+separator;IntPtr statement=IntPtr.Zero;
                    try{var sql="UPDATE threads SET rollout_path = ?1 || substr(rollout_path, length(?2) + 1) WHERE substr(rollout_path, 1, length(?2)) = ?2 COLLATE NOCASE";
                        if(Prepare(db,sql,-1,out statement,IntPtr.Zero)!=0||BindText(statement,1,target,-1,new IntPtr(-1))!=0||BindText(statement,2,old,-1,new IntPtr(-1))!=0||Step(statement)!=101)throw new AppError("The shared workspace database could not be updated. Its data was preserved.");
                    }finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);}
                }if(Exec(db,"COMMIT",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)throw new AppError("The shared workspace database could not be updated. Its data was preserved.");}
                catch{Exec(db,"ROLLBACK",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);throw;}
            }finally{if(db!=IntPtr.Zero)Close(db);}
        }
    }
    static bool HasRolloutColumn(IntPtr db){IntPtr statement=IntPtr.Zero;try{if(Prepare(db,"PRAGMA table_info(threads)",-1,out statement,IntPtr.Zero)!=0)return false;while(Step(statement)==100)if(Marshal.PtrToStringUTF8(ColumnText(statement,1))=="rollout_path")return true;return false;}finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);}}
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_open_v2",CallingConvention=CallingConvention.Cdecl)]static extern int Open([MarshalAs(UnmanagedType.LPUTF8Str)]string path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_close",CallingConvention=CallingConvention.Cdecl)]static extern int Close(IntPtr db);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_busy_timeout",CallingConvention=CallingConvention.Cdecl)]static extern int BusyTimeout(IntPtr db,int ms);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_prepare_v2",CallingConvention=CallingConvention.Cdecl)]static extern int Prepare(IntPtr db,[MarshalAs(UnmanagedType.LPUTF8Str)]string sql,int count,out IntPtr statement,IntPtr tail);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_bind_text",CallingConvention=CallingConvention.Cdecl)]static extern int BindText(IntPtr statement,int index,[MarshalAs(UnmanagedType.LPUTF8Str)]string text,int count,IntPtr destroy);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_step",CallingConvention=CallingConvention.Cdecl)]static extern int Step(IntPtr statement);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_text",CallingConvention=CallingConvention.Cdecl)]static extern IntPtr ColumnText(IntPtr statement,int column);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_finalize",CallingConvention=CallingConvention.Cdecl)]static extern int FinalizeStatement(IntPtr statement);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_exec",CallingConvention=CallingConvention.Cdecl)]static extern int Exec(IntPtr db,[MarshalAs(UnmanagedType.LPUTF8Str)]string sql,IntPtr callback,IntPtr context,IntPtr error);
}
