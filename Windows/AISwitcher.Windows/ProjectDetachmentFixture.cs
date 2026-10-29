using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static partial class PreviewRunner {
    static async Task ProjectDetachmentAsync(string root){
        var scope=Path.Combine(root,"detachment-fixture");var source=Path.Combine(scope,"workspace");Directory.CreateDirectory(source);
        var folder=Path.Combine(scope,"Project A");Directory.CreateDirectory(folder);
        var state=new JsonObject{["local-projects"]=new JsonObject{["local-a"]=new JsonObject{["id"]="local-a",["name"]="A",["rootPaths"]=new JsonArray(folder),["chatGptBacking"]=new JsonObject{["accountId"]="account-one",["projectId"]="g-p-cloud"}}},["thread-project-assignments"]=new JsonObject{["old-chat"]=new JsonObject{["projectKind"]="local",["projectId"]="local-a",["projectOrigin"]="chatgpt"}}};
        var originalState=state.ToJsonString();File.WriteAllText(Path.Combine(source,".codex-global-state.json"),originalState);
        var database=Path.Combine(source,"state_5.sqlite");var linked="{\"codex.localProjectId\":\"local-a\",\"codex.chatGptBacking\":\"fixture-owner\",\"appearance.color\":\"mint\"}";
        var cloud="{\"codex.localProjectId\":\"g-p-cloud\",\"codex.chatGptBacking\":\"cloud-owner\"}";
        FixtureSql(database,"CREATE TABLE projects (id TEXT PRIMARY KEY,metadata TEXT);CREATE TABLE project_roots (project_id TEXT,path TEXT);CREATE TABLE threads (id TEXT,project_id TEXT,creator_account_id TEXT,rollout_path TEXT);");
        FixtureSql(database,"INSERT INTO projects VALUES (?1,?2)","local-a",linked);FixtureSql(database,"INSERT INTO projects VALUES (?1,?2)","g-p-cloud",cloud);
        FixtureSql(database,"INSERT INTO project_roots VALUES (?1,?2)","local-a",folder);FixtureSql(database,"INSERT INTO project_roots VALUES (?1,?2)","g-p-cloud",folder);
        FixtureSql(database,"INSERT INTO threads VALUES ('old-chat','local-a','account-one','unrelated-original-path')");
        var blocked=Path.Combine(scope,"blocked-recovery");File.WriteAllText(blocked,"preserve");bool rejected=false;
        try{WorkspaceIndex.DetachLocalProjectAccounts(source,blocked);}catch(IOException){rejected=true;}
        Require(rejected&&FixtureScalar(database,"SELECT metadata FROM projects WHERE id='local-a'")==linked,"Failed recovery save modified project metadata");
        var repo=new Repository(Path.Combine(scope,"manager"),Path.Combine(scope,"backends"));var account=new Account{Name="A",SharesLocalWorkspace=true};repo.Save(new(){Accounts=[account]});repo.PrepareQuota(account);repo.PrepareProfile(account);var prefs=new Preferences();prefs.Executables["workspace"]=source;
        await SharedWorkspace.PrepareAsync(account,repo,prefs);
        var projected=JsonNode.Parse(File.ReadAllText(Path.Combine(repo.QuotaHome(account),".codex-global-state.json")))!;
        Require(projected["local-projects"]!["local-a"]!["chatGptBacking"]==null&&projected["thread-project-assignments"]!["old-chat"]!["projectId"]!.GetValue<string>()=="local-a","Projected state still links local project to account");
        Require(File.ReadAllText(Path.Combine(source,".codex-global-state.json"))==originalState,"Original workspace UI state was overwritten");
        var detached=JsonNode.Parse(FixtureScalar(database,"SELECT metadata FROM projects WHERE id='local-a'"))!;
        Require(detached["codex.chatGptBacking"]==null&&detached["appearance.color"]!.GetValue<string>()=="mint","Native local project detachment changed unrelated metadata");
        Require(FixtureScalar(database,"SELECT metadata FROM projects WHERE id='g-p-cloud'")==cloud,"Cloud project ownership changed");
        Require(FixtureScalar(database,"SELECT id||'|'||project_id||'|'||creator_account_id||'|'||rollout_path FROM threads")=="old-chat|local-a|account-one|unrelated-original-path","Detachment changed conversation identity, creator or project membership");
        Require(FixtureScalar(database,"SELECT path FROM project_roots WHERE project_id='local-a'")==folder,"Project folder changed");
        var recovery=Path.Combine(repo.Root,"SharedWorkspaceAccountLinks");var backups=Directory.GetFiles(recovery,"*.json");Require(backups.Length>=2&&backups.Any(x=>File.ReadAllText(x).Contains("fixture-owner")),"Original account association was not saved for recovery");
        await SharedWorkspace.PrepareAsync(account,repo,prefs);Require(Directory.GetFiles(recovery,"*.json").Length==backups.Length,"Repeated preparation duplicated recovery data");
    }
    static void FixtureSql(string path,string sql,params string[] values){
        Require(SqlOpen(path,out var db,6,IntPtr.Zero)==0,"Could not open detachment fixture");IntPtr statement=IntPtr.Zero;try{
            if(values.Length==0){Require(SqlExec(db,sql,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)==0,"Could not create detachment fixture");return;}
            Require(SqlPrepare(db,sql,-1,out statement,IntPtr.Zero)==0,"Could not prepare detachment fixture");for(var i=0;i<values.Length;i++)Require(SqlBind(statement,i+1,values[i],-1,new IntPtr(-1))==0,"Could not bind fixture value");Require(SqlStep(statement)==101,"Could not write detachment fixture");
        }finally{if(statement!=IntPtr.Zero)SqlFinalize(statement);SqlClose(db);}
    }
    static string FixtureScalar(string path,string sql){
        Require(SqlOpen(path,out var db,2,IntPtr.Zero)==0,"Could not open detachment result");IntPtr statement=IntPtr.Zero;try{Require(SqlPrepare(db,sql,-1,out statement,IntPtr.Zero)==0&&SqlStep(statement)==100,"Missing detachment result");return Marshal.PtrToStringUTF8(SqlColumn(statement,0))!;}finally{if(statement!=IntPtr.Zero)SqlFinalize(statement);SqlClose(db);}
    }
}
