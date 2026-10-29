using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static partial class WorkspaceIndex {
    // Run before the Desktop client opens. Authentication and thread/session IDs
    // are deliberately outside this migration. SQLite updates are transactional.
    public static void DetachLocalProjectAccounts(string databaseHome,string recovery){
        Repository.RejectLinks(databaseHome);Repository.RejectLinks(recovery);Directory.CreateDirectory(recovery);
        foreach(var path in Directory.EnumerateFiles(databaseHome,"state_*.sqlite")){
            Repository.RejectLinks(path);IntPtr db=IntPtr.Zero;
            try{
                if(Open(path,out db,2,IntPtr.Zero)!=0)throw Failure();BusyTimeout(db,5000);
                if(!HasColumns(db,"projects","id","metadata")||!HasColumns(db,"project_roots","project_id","path"))continue;
                if(Exec(db,"BEGIN IMMEDIATE",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)throw Failure();
                try{
                    var changes=new List<(string Id,string Original,string Updated)>();IntPtr statement=IntPtr.Zero;
                    try{
                        if(Prepare(db,"SELECT id, metadata FROM projects",-1,out statement,IntPtr.Zero)!=0)throw Failure();
                        int step;while((step=Step(statement))==100){
                            var id=Marshal.PtrToStringUTF8(ColumnText(statement,0))!;var original=Marshal.PtrToStringUTF8(ColumnText(statement,1))!;
                            if(JsonNode.Parse(original) is not JsonObject metadata)throw Failure();
                            var updated=SharedLocalProjects.DetachedMetadata(id,metadata,ProjectRoots(db,id));
                            if(updated!=null)changes.Add((id,original,updated.ToJsonString()));
                        }if(step!=101)throw Failure();
                    }finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);}
                    foreach(var change in changes){
                        SaveRecovery(recovery,Path.GetFullPath(path)+"\n"+change.Id+"\n"+change.Original,new JsonObject{["database"]=Path.GetFullPath(path),["projectId"]=change.Id,["metadata"]=change.Original});
                        statement=IntPtr.Zero;try{
                            if(Prepare(db,"UPDATE projects SET metadata=?1 WHERE id=?2 AND metadata=?3",-1,out statement,IntPtr.Zero)!=0||BindText(statement,1,change.Updated,-1,new IntPtr(-1))!=0||BindText(statement,2,change.Id,-1,new IntPtr(-1))!=0||BindText(statement,3,change.Original,-1,new IntPtr(-1))!=0||Step(statement)!=101)throw Failure();
                        }finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);}
                    }
                    if(Exec(db,"COMMIT",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)throw Failure();
                }catch{Exec(db,"ROLLBACK",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);throw;}
            }finally{if(db!=IntPtr.Zero)Close(db);}
        }
    }
    public static void SaveRecovery(string directory,string key,JsonObject original){
        Repository.RejectLinks(directory);Directory.CreateDirectory(directory);
        var file=Path.Combine(directory,Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant()+".json");Repository.RejectLinks(file);
        if(File.Exists(file)){if(!JsonNode.DeepEquals(JsonNode.Parse(File.ReadAllText(file)),original))throw Failure();return;}
        var temp=file+".tmp";Repository.RejectLinks(temp);File.WriteAllText(temp,original.ToJsonString());File.Move(temp,file,false);
    }
    static IEnumerable<string> ProjectRoots(IntPtr db,string id){
        IntPtr statement=IntPtr.Zero;try{
            if(Prepare(db,"SELECT path FROM project_roots WHERE project_id=?1",-1,out statement,IntPtr.Zero)!=0||BindText(statement,1,id,-1,new IntPtr(-1))!=0)throw Failure();
            var roots=new List<string>();int step;while((step=Step(statement))==100)roots.Add(Marshal.PtrToStringUTF8(ColumnText(statement,0))!);if(step!=101)throw Failure();return roots;
        }finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);}
    }
    static bool HasColumns(IntPtr db,string table,params string[] names){
        IntPtr statement=IntPtr.Zero;try{
            if(Prepare(db,"PRAGMA table_info("+table+")",-1,out statement,IntPtr.Zero)!=0)throw Failure();
            var found=new HashSet<string>();int step;while((step=Step(statement))==100)found.Add(Marshal.PtrToStringUTF8(ColumnText(statement,1))!);if(step!=101)throw Failure();return names.All(found.Contains);
        }finally{if(statement!=IntPtr.Zero)FinalizeStatement(statement);}
    }
    static AppError Failure()=>new("The shared workspace database could not be updated. Its data was preserved.");
}
