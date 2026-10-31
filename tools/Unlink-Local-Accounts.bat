@echo off
setlocal
set "AISW_UNLINK_SELF=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $raw=[IO.File]::ReadAllText($env:AISW_UNLINK_SELF); $parts=$raw -split '(?m)^# AISW_POWERSHELL_PAYLOAD\r?$',2; if($parts.Length -ne 2){throw 'Missing tool payload'}; & ([scriptblock]::Create($parts[1])) } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }"
set "AISW_UNLINK_EXIT=%ERRORLEVEL%"
echo.
if not "%AISW_UNLINK_SELF_TEST%"=="1" pause
exit /b %AISW_UNLINK_EXIT%
# AISW_POWERSHELL_PAYLOAD
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$source = @'
using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

public static class LocalAccountUnlink {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 67108864, RecursionLimit = 512 };
    static readonly string[] UiKeys = { "chatGptBacking", "chatGptBackingCreation", "retiredChatGptBacking", "chatGptBackingRecoveryPending" };
    static readonly string[] DbKeys = { "codex.chatGptBacking", "codex.chatGptBackingCreation", "codex.retiredChatGptBacking" };
    public sealed class Row { public string File, Id, Name, Before, After; }
    public sealed class Document { public string File, BeforeHash, After, Backup, AfterHash; }
    public sealed class Plan { public List<Row> Rows = new List<Row>(); public List<Document> Documents = new List<Document>(); public List<string> Projects = new List<string>(); }
    public sealed class Journal { public string Format = "ai-switcher-local-unlink-1"; public List<Row> Rows; public List<Document> Documents; }
    static Dictionary<string,object> Object(object value) { return value as Dictionary<string,object>; }
    static object Get(Dictionary<string,object> value, string key) { object result; return value != null && value.TryGetValue(key, out result) ? result : null; }
    static string Text(Dictionary<string,object> value, string key) { return Get(value,key) as string; }
    static IEnumerable<object> Items(object value) { var items=value as IEnumerable; return value == null || value is string || value is IDictionary || items == null ? new object[0] : items.Cast<object>(); }
    static string Hash(byte[] bytes) { using(var hash=SHA256.Create())return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-","").ToLowerInvariant(); }
    static void SafePath(string path) {
        path=Path.GetFullPath(path);for(var current=path;!String.IsNullOrEmpty(current);current=Path.GetDirectoryName(current)) {
            if((File.Exists(current)||Directory.Exists(current))&&(File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)throw new IOException("Linked storage is not modified: "+current);
            if(current==Path.GetPathRoot(current))break;
        }
    }
    static string Read(string path) { SafePath(path);var info=new FileInfo(path);if(info.Length>67108864)throw new IOException("JSON file is too large: "+path);return File.ReadAllText(path,Encoding.UTF8); }
    static Dictionary<string,object> ReadObject(string path) { var value=Object(Json.DeserializeObject(Read(path)));if(value==null)throw new IOException("Invalid JSON object: "+path);return value; }
    static bool IsLocal(string id, string[] roots) {
        return !String.IsNullOrWhiteSpace(id)&&!id.StartsWith("g-p-",StringComparison.OrdinalIgnoreCase)&&roots.Length>0&&roots.All(p=>!String.IsNullOrWhiteSpace(p)&&Path.IsPathRooted(p)&&!Regex.IsMatch(p.Replace('\\','/'),@"(^|/)\.chatgpt-projects(/|$)",RegexOptions.IgnoreCase));
    }
    static bool Remove(Dictionary<string,object> value,string[] keys) { bool changed=false;foreach(var key in keys)changed=value.Remove(key)||changed;return changed; }
    static string Full(string path) { return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path)); }
    static void Add(HashSet<string> values,string value) { if(!String.IsNullOrWhiteSpace(value))values.Add(Full(value)); }
    static void Source(HashSet<string> homes,HashSet<string> databases,string home) {
        if(String.IsNullOrWhiteSpace(home))return;home=Full(home);Add(homes,home);Add(databases,home);
        var config=Path.Combine(home,"config.toml");if(!File.Exists(config))return;
        foreach(var line in Read(config).Split('\n')) {
            var value=line.Trim();if(value.StartsWith("[",StringComparison.Ordinal))break;
            if(!Regex.IsMatch(value,@"^sqlite_home\s*="))continue;
            var match=Regex.Match(value,"^sqlite_home\\s*=\\s*(\"(?:\\\\.|[^\"\\\\])*\"|'[^']*')\\s*(?:#.*)?$");
            if(!match.Success)throw new IOException("Unsupported sqlite_home. Use the workspace folder recorded in AI Switcher Settings: "+config);
            var literal=match.Groups[1].Value;var path=literal[0]=='\''?literal.Substring(1,literal.Length-2):Json.Deserialize<string>(literal);
            if(path.StartsWith("~/")||path.StartsWith("~\\"))path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),path.Substring(2));
            Add(databases,Path.IsPathRooted(path)?path:Path.Combine(home,path));break;
        }
    }
    public static Plan Discover(string extra) {
        var homes=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var databases=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var managers=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var user=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);Source(homes,databases,Path.Combine(user,".codex"));Source(homes,databases,Environment.GetEnvironmentVariable("CODEX_HOME"));Source(homes,databases,extra);
        Add(managers,Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"AISwitcher"));
        var backends=Path.Combine(user,".aisw");if(Directory.Exists(backends)) {
            SafePath(backends);foreach(var home in Directory.GetDirectories(backends,"win-*")) {
                SafePath(home);var owner=Path.Combine(home,"ai-switcher-profile.json");if(!File.Exists(owner))continue;
                Add(managers,Text(ReadObject(owner),"root"));Add(homes,home);Add(databases,home);
                var marker=Path.Combine(home,"ai-switcher-workspace.json");if(File.Exists(marker)){var data=ReadObject(marker);Source(homes,databases,Text(data,"source"));Add(databases,Text(data,"database"));}
            }
        }
        foreach(var manager in managers.ToArray()) {
            var preferences=Path.Combine(manager,"preferences.json");if(!File.Exists(preferences))continue;
            var executables=Object(Get(ReadObject(preferences),"executables"));if(executables!=null){Source(homes,databases,Text(executables,"workspace"));Add(databases,Text(executables,"database"));}
        }
        var documents=new HashSet<string>(StringComparer.OrdinalIgnoreCase);foreach(var home in homes) {var file=Path.Combine(home,".codex-global-state.json");if(File.Exists(file))documents.Add(file);}
        foreach(var manager in managers) {var archive=Path.Combine(manager,"SharedWorkspaceMetadata");if(Directory.Exists(archive)){SafePath(archive);foreach(var file in Directory.GetFiles(archive,"*.json"))documents.Add(file);}}
        var dbFiles=new HashSet<string>(StringComparer.OrdinalIgnoreCase);foreach(var directory in databases)if(Directory.Exists(directory)){SafePath(directory);foreach(var file in Directory.GetFiles(directory,"state_*.sqlite"))dbFiles.Add(file);}
        return Scan(documents.ToArray(),dbFiles.ToArray());
    }
    public static Plan Scan(string[] documents,string[] databases) {
        var plan=new Plan();foreach(var path in documents.OrderBy(x=>x)) {
            var document=ReadObject(path);var state=Object(Get(document,"metadata"))??document;var projects=Object(Get(state,"local-projects"));if(projects==null)continue;
            var ids=new HashSet<string>(StringComparer.Ordinal);bool changed=false;
            foreach(var pair in projects) {
                var project=Object(pair.Value);if(project==null)continue;var roots=Items(Get(project,"rootPaths")).Select(x=>x as string).ToArray();
                if(!IsLocal(pair.Key,roots)||!IsLocal(Text(project,"id")??pair.Key,roots))continue;ids.Add(pair.Key);
                if(Remove(project,UiKeys)){changed=true;plan.Projects.Add((Text(project,"name")??pair.Key)+" | "+String.Join("; ",roots));}
            }
            var assignments=Object(Get(state,"thread-project-assignments"));if(assignments!=null)foreach(var pair in assignments) {
                var assignment=Object(pair.Value);if(Text(assignment,"projectKind")=="local"&&ids.Contains(Text(assignment,"projectId")??"")&&Text(assignment,"projectOrigin")=="chatgpt"){assignment.Remove("projectOrigin");changed=true;}
            }
            if(changed)plan.Documents.Add(new Document{File=Full(path),BeforeHash=Hash(File.ReadAllBytes(path)),After=Json.Serialize(document)});
        }
        foreach(var file in databases.OrderBy(x=>x))using(var db=new Database(file,false)) {
            if(!db.Columns("projects","id","name","metadata")||!db.Columns("project_roots","project_id","path"))continue;
            foreach(var row in db.Query("SELECT id,name,metadata FROM projects")) {
                var id=row[0];var metadata=Object(Json.DeserializeObject(row[2]));if(metadata==null)throw new IOException("Invalid project metadata: "+file);
                var roots=db.Query("SELECT path FROM project_roots WHERE project_id=?1",id).Select(x=>x[0]).ToArray();
                if(!IsLocal(id,roots)||!IsLocal(Text(metadata,"codex.localProjectId")??id,roots)||!Remove(metadata,DbKeys))continue;
                plan.Rows.Add(new Row{File=Full(file),Id=id,Name=row[1],Before=row[2],After=Json.Serialize(metadata)});plan.Projects.Add(row[1]+" | "+String.Join("; ",roots));
            }
        }
        return plan;
    }
    public static void CheckApps() {
        var names=new List<string>();foreach(var process in Process.GetProcesses())using(process) {
            try{var name=process.ProcessName;if(name.Equals("ChatGPT",StringComparison.OrdinalIgnoreCase)||name.Equals("Codex",StringComparison.OrdinalIgnoreCase)||name.Equals("AISwitcher",StringComparison.OrdinalIgnoreCase)||name.StartsWith("AI-Switcher",StringComparison.OrdinalIgnoreCase))names.Add(name+" ("+process.Id+")");}catch(InvalidOperationException){}
        }
        if(names.Count>0)throw new IOException("Close these apps and their background sessions first: "+String.Join(", ",names.Distinct()));
    }
    static void Validate(Plan plan,bool restoring) {
        foreach(var document in plan.Documents){SafePath(document.File);var hash=Hash(File.ReadAllBytes(document.File));if(hash!=document.BeforeHash&&(!restoring||hash!=document.AfterHash))throw new IOException("UI state changed. Nothing further was modified: "+document.File);}
        foreach(var group in plan.Rows.GroupBy(x=>x.File))using(var db=new Database(group.Key,false))foreach(var row in group) {
            var current=db.Query("SELECT metadata FROM projects WHERE id=?1",row.Id);if(current.Count!=1||(current[0][0]!=row.Before&&(!restoring||current[0][0]!=row.After)))throw new IOException("Project metadata changed. Nothing further was modified: "+row.Name);
        }
    }
    static void Atomic(string path,byte[] value) {
        SafePath(path);var temp=Path.Combine(Path.GetDirectoryName(path),".aisw-unlink-"+Guid.NewGuid().ToString("N")+".tmp");
        try{using(var file=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None)){file.Write(value,0,value.Length);file.Flush(true);}File.Replace(temp,path,null);}finally{if(File.Exists(temp))File.Delete(temp);}
    }
    static void Rows(IEnumerable<Row> rows,bool restore) {
        foreach(var group in rows.GroupBy(x=>x.File))using(var db=new Database(group.Key,true)) {
            db.Execute("BEGIN IMMEDIATE");try{foreach(var row in group) {
                var from=restore?row.After:row.Before;var to=restore?row.Before:row.After;var current=db.Query("SELECT metadata FROM projects WHERE id=?1",row.Id);
                if(restore&&current.Count==1&&current[0][0]==row.Before)continue;
                if(current.Count!=1||current[0][0]!=from)throw new IOException("Project changed while updating: "+row.Name);
                db.Execute("UPDATE projects SET metadata=?1 WHERE id=?2 AND metadata=?3",to,row.Id,from);if(db.Changes()!=1)throw new IOException("Project was not updated: "+row.Name);
            }db.Execute("COMMIT");}catch{db.Execute("ROLLBACK");throw;}
        }
    }
    public static string Apply(Plan plan,string folder,bool checkApps) {
        if(checkApps)CheckApps();Validate(plan,false);SafePath(folder);if(Directory.Exists(folder)||File.Exists(folder))throw new IOException("Backup folder must be new.");Directory.CreateDirectory(folder);
        int index=0;foreach(var path in plan.Rows.Select(x=>x.File).Distinct(StringComparer.OrdinalIgnoreCase))using(var db=new Database(path,false))db.Backup(Path.Combine(folder,"database-"+(index++)+".sqlite"));
        index=0;foreach(var document in plan.Documents) {document.Backup="ui-"+(index++)+".json";File.Copy(document.File,Path.Combine(folder,document.Backup),false);document.AfterHash=Hash(new UTF8Encoding(false).GetBytes(document.After));}
        File.WriteAllText(Path.Combine(folder,"restore-journal.json"),Json.Serialize(new Journal{Rows=plan.Rows,Documents=plan.Documents}),new UTF8Encoding(false));
        Validate(plan,false);try {
            if(checkApps)CheckApps();Rows(plan.Rows,false);foreach(var document in plan.Documents){if(checkApps)CheckApps();if(Hash(File.ReadAllBytes(document.File))!=document.BeforeHash)throw new IOException("UI state changed during update: "+document.File);Atomic(document.File,new UTF8Encoding(false).GetBytes(document.After));}
        }catch(Exception error) {
            try{Restore(folder,checkApps);}catch(Exception rollback){throw new IOException("Update stopped. Recovery may be needed from "+folder+". "+rollback.Message,error);}
            throw new IOException("Update failed; original metadata was restored. Backup: "+folder,error);
        }
        return folder;
    }
    public static void Restore(string folder,bool checkApps) {
        if(checkApps)CheckApps();SafePath(folder);var journalText=Read(Path.Combine(folder,"restore-journal.json"));if(Text(Object(Json.DeserializeObject(journalText)),"Format")!="ai-switcher-local-unlink-1")throw new IOException("Invalid recovery journal.");var journal=Json.Deserialize<Journal>(journalText);if(journal==null||journal.Rows==null||journal.Documents==null)throw new IOException("Invalid recovery journal.");
        foreach(var row in journal.Rows)if(!Regex.IsMatch(Path.GetFileName(row.File),@"^state_[A-Za-z0-9_-]+\.sqlite$"))throw new IOException("Invalid database recovery target.");
        foreach(var document in journal.Documents){if(Path.GetFileName(document.Backup)!=document.Backup||!Regex.IsMatch(document.Backup,@"^ui-\d+\.json$"))throw new IOException("Invalid recovery file.");if(Path.GetFileName(document.File)!=".codex-global-state.json"&&Path.GetFileName(Path.GetDirectoryName(document.File))!="SharedWorkspaceMetadata")throw new IOException("Invalid UI recovery target.");var backup=Path.Combine(folder,document.Backup);SafePath(backup);if(Hash(File.ReadAllBytes(backup))!=document.BeforeHash)throw new IOException("Recovery copy changed: "+backup);}
        var plan=new Plan{Rows=journal.Rows,Documents=journal.Documents};Validate(plan,true);Rows(plan.Rows,true);foreach(var document in plan.Documents){if(checkApps)CheckApps();if(Hash(File.ReadAllBytes(document.File))!=document.BeforeHash)Atomic(document.File,File.ReadAllBytes(Path.Combine(folder,document.Backup)));}
    }
    sealed class Database : IDisposable {
        IntPtr db;
        public Database(string path,bool write) {SafePath(path);if(!File.Exists(path))throw new IOException("Database not found: "+path);if(Open(path,out db,write?2:1,IntPtr.Zero)!=0){if(db!=IntPtr.Zero)Close(db);db=IntPtr.Zero;throw new IOException("Cannot open database: "+path);}Busy(db,3000);}
        public bool Columns(string table,params string[] columns) {var found=Query("PRAGMA table_info("+table+")").Select(x=>x[1]).ToArray();return columns.All(found.Contains);}
        public List<string[]> Query(string sql,params string[] values) {
            IntPtr statement=IntPtr.Zero;try{Prepare(sql,values,out statement);var rows=new List<string[]>();int step;while((step=Step(statement))==100){var row=new string[ColumnCount(statement)];for(var i=0;i<row.Length;i++)row[i]=Utf8(Column(statement,i));rows.Add(row);}if(step!=101)throw new IOException("SQLite read failed or database is busy.");return rows;}finally{if(statement!=IntPtr.Zero)FinalizeSql(statement);}
        }
        void Prepare(string sql,string[] values,out IntPtr statement){if(PrepareNative(db,sql,-1,out statement,IntPtr.Zero)!=0)throw new IOException("Unsupported or unavailable local database schema.");for(var i=0;i<values.Length;i++){var data=Encoding.UTF8.GetBytes(values[i]);if(Bind(statement,i+1,data,data.Length,new IntPtr(-1))!=0)throw new IOException("SQLite parameter failed.");}}
        public void Execute(string sql,params string[] values) {IntPtr statement=IntPtr.Zero;try{Prepare(sql,values,out statement);if(Step(statement)!=101)throw new IOException("SQLite update failed or database is busy.");}finally{if(statement!=IntPtr.Zero)FinalizeSql(statement);}}
        public int Changes(){return ChangeCount(db);}
        public void Backup(string path) {
            SafePath(path);if(File.Exists(path))throw new IOException("Backup already exists.");IntPtr target=IntPtr.Zero,backup=IntPtr.Zero;
            try{if(Open(path,out target,6,IntPtr.Zero)!=0)throw new IOException("Cannot create database backup.");backup=BackupInit(target,"main",db,"main");if(backup==IntPtr.Zero||BackupStep(backup,-1)!=101)throw new IOException("Cannot back up the local database, including pending WAL data.");var code=BackupFinish(backup);backup=IntPtr.Zero;if(code!=0)throw new IOException("Database backup did not finish.");}finally{if(backup!=IntPtr.Zero)BackupFinish(backup);if(target!=IntPtr.Zero)Close(target);}
        }
        public void Dispose(){if(db!=IntPtr.Zero){Close(db);db=IntPtr.Zero;}}
    }
    static void Assert(bool value,string message){if(!value)throw new Exception("TEST FAILED: "+message);}
    static void Seed(string file,string sql,params string[] values){using(var db=new Database(file,true))db.Execute(sql,values);}
    static string Scalar(string file,string sql){using(var db=new Database(file,false))return db.Query(sql)[0][0];}
    public static void SelfTest() {
        var root=Path.Combine(Path.GetTempPath(),"ai-switcher-unlink-tests."+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        try {
            var project=Path.Combine(root,"Project A quoted ' and Unicode \u0111");Directory.CreateDirectory(project);
            var dbFile=Path.Combine(root,"state_5.sqlite");File.WriteAllBytes(dbFile,new byte[0]);
            Seed(dbFile,"CREATE TABLE projects (id TEXT PRIMARY KEY,name TEXT,metadata TEXT)");Seed(dbFile,"CREATE TABLE project_roots (project_id TEXT,path TEXT)");Seed(dbFile,"CREATE TABLE threads (id TEXT,project_id TEXT,creator_account_id TEXT)");
            var metadata="{\"codex.localProjectId\":\"local-a\",\"codex.chatGptBacking\":\"old-account\",\"appearance.color\":\"mint\"}";
            Seed(dbFile,"INSERT INTO projects VALUES (?1,?2,?3)","native-a","Local A",metadata);Seed(dbFile,"INSERT INTO project_roots VALUES (?1,?2)","native-a",project);
            var cloud="{\"codex.localProjectId\":\"g-p-cloud\",\"codex.chatGptBacking\":\"cloud-owner\"}";
            Seed(dbFile,"INSERT INTO projects VALUES (?1,?2,?3)","cloud-native","Cloud mirror",cloud);Seed(dbFile,"INSERT INTO project_roots VALUES (?1,?2)","cloud-native",project);
            Seed(dbFile,"INSERT INTO projects VALUES (?1,?2,?3)","managed","Managed folder",metadata);Seed(dbFile,"INSERT INTO project_roots VALUES (?1,?2)","managed",Path.Combine(root,".chatgpt-projects","mirror"));
            Seed(dbFile,"INSERT INTO threads VALUES ('old-chat','native-a','old-account')");
            var state=new Dictionary<string,object>{{"local-projects",new Dictionary<string,object>{{"local-a",new Dictionary<string,object>{{"id","local-a"},{"name","Local A"},{"rootPaths",new string[]{project}},{"chatGptBacking",new Dictionary<string,object>{{"accountId","old-account"}}},{"chatGptBackingCreation","old-account"},{"retiredChatGptBacking","old-account"},{"chatGptBackingRecoveryPending",true}}},{"g-p-cloud",new Dictionary<string,object>{{"id","g-p-cloud"},{"rootPaths",new string[]{project}},{"chatGptBacking","cloud-owner"}}}}},{"thread-project-assignments",new Dictionary<string,object>{{"old-chat",new Dictionary<string,object>{{"projectKind","local"},{"projectId","local-a"},{"projectOrigin","chatgpt"}}}}},{"unrelated-number",123456789012345678L}};
            var ui=Path.Combine(root,".codex-global-state.json");var bytes=new UTF8Encoding(true).GetPreamble().Concat(Encoding.UTF8.GetBytes(Json.Serialize(state))).ToArray();File.WriteAllBytes(ui,bytes);
            var archives=Path.Combine(root,"SharedWorkspaceMetadata");Directory.CreateDirectory(archives);var archive=Path.Combine(archives,"fixture.json");File.WriteAllText(archive,Json.Serialize(new Dictionary<string,object>{{"metadata",state},{"source",root}}));
            var auth=Path.Combine(root,"auth.json");File.WriteAllText(auth,"fictional-auth-sentinel");var transcript=Path.Combine(root,"session-sentinel.jsonl");File.WriteAllText(transcript,"fictional-transcript-sentinel");
            var plan=Scan(new string[]{ui,archive},new string[]{dbFile});Assert(plan.Rows.Count==1&&plan.Documents.Count==2,"Scoped project and source/archive discovery");
            File.AppendAllText(ui," ");bool refused=false;try{Apply(plan,Path.Combine(root,"stale-backup"),false);}catch(IOException){refused=true;}Assert(refused&&!Directory.Exists(Path.Combine(root,"stale-backup")),"Stale plans refused before any write");File.WriteAllBytes(ui,bytes);
            var backup=Path.Combine(root,"backup");using(var wal=new Database(dbFile,true)){wal.Query("PRAGMA journal_mode=WAL");wal.Execute("INSERT INTO threads VALUES ('wal-chat','native-a','old-account')");Apply(plan,backup,false);}
            Assert(Scalar(dbFile,"SELECT metadata FROM projects WHERE id='native-a'").Contains("appearance.color")&&!Scalar(dbFile,"SELECT metadata FROM projects WHERE id='native-a'").Contains("codex.chatGptBacking"),"Only known DB links removed");
            Assert(Scalar(dbFile,"SELECT metadata FROM projects WHERE id='cloud-native'")==cloud&&Scalar(dbFile,"SELECT metadata FROM projects WHERE id='managed'")==metadata,"Cloud and managed project ownership preserved");
            Assert(Scalar(dbFile,"SELECT id||'|'||project_id||'|'||creator_account_id FROM threads WHERE id='old-chat'")=="old-chat|native-a|old-account","Chat ID, membership and creator preserved");
            Assert(File.ReadAllText(auth)=="fictional-auth-sentinel"&&File.ReadAllText(transcript)=="fictional-transcript-sentinel","Authentication and messages untouched");
            Assert(Scan(new string[]{ui,archive},new string[]{dbFile}).Rows.Count==0&&Scan(new string[]{ui,archive},new string[]{dbFile}).Documents.Count==0,"Idempotent detachment including archives");
            var updated=ReadObject(ui);Assert(Object(Get(Object(Get(updated,"local-projects")),"g-p-cloud")).ContainsKey("chatGptBacking"),"UI cloud backing preserved");
            Assert(Text(Object(Get(Object(Get(updated,"thread-project-assignments")),"old-chat")),"projectId")=="local-a","Chat remains in original project");
            Assert(!Object(Get(Object(Get(updated,"thread-project-assignments")),"old-chat")).ContainsKey("projectOrigin"),"Local chat origin detached");
            Assert(Convert.ToInt64(Get(updated,"unrelated-number"))==123456789012345678L,"Unrelated large integers preserved");
            using(var copy=new Database(Path.Combine(backup,"database-0.sqlite"),false)){Assert(copy.Query("SELECT metadata FROM projects WHERE id='native-a'")[0][0]==metadata,"SQLite backup is readable and contains original data");Assert(copy.Query("SELECT count(*) FROM threads WHERE id='wal-chat'")[0][0]=="1","SQLite backup includes committed WAL data");}
            Seed(dbFile,"INSERT INTO threads VALUES ('new-chat','native-a','new-account')");Restore(backup,false);
            Assert(Scalar(dbFile,"SELECT count(*) FROM threads")=="3","Restore preserves newly added conversations");Assert(Scalar(dbFile,"SELECT metadata FROM projects WHERE id='native-a'")==metadata,"Original project association restored");Assert(File.ReadAllBytes(ui).SequenceEqual(bytes),"JSON restore preserves exact original bytes and BOM");
            var again=Scan(new string[]{ui},new string[]{dbFile});Apply(again,Path.Combine(root,"backup-two"),false);File.AppendAllText(ui," ");refused=false;try{Restore(Path.Combine(root,"backup-two"),false);}catch(IOException){refused=true;}Assert(refused,"Changed UI state is never overwritten by restore");
            var malformed=Path.Combine(root,"bad.json");File.WriteAllText(malformed,"{invalid");refused=false;try{Scan(new string[]{malformed},new string[0]);}catch{refused=true;}Assert(refused,"Malformed state rejected before mutation");
            Console.WriteLine("PASS: WinPS/C# compilation; SQLite backup; scoped local DB/UI/archive unlink; Unicode/quoted paths; cloud and managed-folder exclusions; exact chat/project IDs; auth/transcript preservation; large integers; idempotency; stale-plan rejection; metadata-only restore preserving new chats; byte-exact JSON restore; changed-state and malformed-JSON guards.");
        }finally{Directory.Delete(root,true);}
    }
    static string Utf8(IntPtr value){if(value==IntPtr.Zero)return null;int length=0;while(Marshal.ReadByte(value,length)!=0)length++;var bytes=new byte[length];Marshal.Copy(value,bytes,0,length);return Encoding.UTF8.GetString(bytes);}
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_open_v2",CallingConvention=CallingConvention.Cdecl)]static extern int Open([MarshalAs(UnmanagedType.LPUTF8Str)]string path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_close",CallingConvention=CallingConvention.Cdecl)]static extern int Close(IntPtr db);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_busy_timeout",CallingConvention=CallingConvention.Cdecl)]static extern int Busy(IntPtr db,int ms);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_prepare_v2",CallingConvention=CallingConvention.Cdecl)]static extern int PrepareNative(IntPtr db,[MarshalAs(UnmanagedType.LPUTF8Str)]string sql,int length,out IntPtr statement,IntPtr tail);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_bind_text",CallingConvention=CallingConvention.Cdecl)]static extern int Bind(IntPtr statement,int index,byte[] value,int length,IntPtr destroy);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_step",CallingConvention=CallingConvention.Cdecl)]static extern int Step(IntPtr statement);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_finalize",CallingConvention=CallingConvention.Cdecl)]static extern int FinalizeSql(IntPtr statement);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_count",CallingConvention=CallingConvention.Cdecl)]static extern int ColumnCount(IntPtr statement);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_text",CallingConvention=CallingConvention.Cdecl)]static extern IntPtr Column(IntPtr statement,int index);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_changes",CallingConvention=CallingConvention.Cdecl)]static extern int ChangeCount(IntPtr db);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_backup_init",CallingConvention=CallingConvention.Cdecl)]static extern IntPtr BackupInit(IntPtr target,string targetName,IntPtr source,string sourceName);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_backup_step",CallingConvention=CallingConvention.Cdecl)]static extern int BackupStep(IntPtr backup,int pages);
    [DllImport("winsqlite3.dll",EntryPoint="sqlite3_backup_finish",CallingConvention=CallingConvention.Cdecl)]static extern int BackupFinish(IntPtr backup);
}

'@
try {
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
    if ($env:AISW_UNLINK_SELF_TEST -eq '1') {
        [LocalAccountUnlink]::SelfTest()
        exit 0
    }
    Write-Host ''
    Write-Host 'AI Switcher - Unlink LOCAL project account associations' -ForegroundColor Cyan
    Write-Host 'Windows 10/11. No downloads, no admin access, no account logout.'
    Write-Host 'Project/chat IDs, messages, files and sign-in credentials are preserved.'
    Write-Host 'Cloud projects are excluded. Historical chat creator IDs are preserved.'
    Write-Host ''
    [LocalAccountUnlink]::CheckApps()
    Write-Host '1 - Inspect and remove local account associations'
    Write-Host '2 - Restore associations from a backup created by this tool'
    Write-Host 'Enter - Cancel'
    $mode = Read-Host 'Choose 1 or 2'
    if ($mode -eq '2') {
        $folder = (Read-Host 'Paste the backup folder path').Trim().Trim('"')
        if ((Read-Host 'Type RESTORE to restore original associations') -cne 'RESTORE') { exit 0 }
        [LocalAccountUnlink]::Restore($folder,$true)
        Write-Host 'Original associations restored. Conversation history was not replaced.' -ForegroundColor Green
        exit 0
    }
    if ($mode -ne '1') { Write-Host 'Cancelled. Nothing changed.'; exit 0 }
    $plan = [LocalAccountUnlink]::Discover($null)
    if ($plan.Rows.Count + $plan.Documents.Count -eq 0) {
        Write-Host 'No removable local associations found in the detected locations.'
        $extra = (Read-Host 'Optional: paste another .codex/workspace folder, or press Enter to finish').Trim().Trim('"')
        if (-not $extra) { exit 0 }
        $plan = [LocalAccountUnlink]::Discover($extra)
    }
    if ($plan.Rows.Count + $plan.Documents.Count -eq 0) { Write-Host 'No matching local associations found. Nothing changed.'; exit 0 }
    Write-Host ''
    Write-Host 'Local projects affected (the same project may appear in several profiles):' -ForegroundColor Yellow
    $plan.Projects | Sort-Object -Unique | ForEach-Object { Write-Host ('  ' + $_) }
    Write-Host ''
    Write-Host ('Project database entries: ' + $plan.Rows.Count)
    Write-Host ('Source/profile/sidebar JSON files: ' + $plan.Documents.Count)
    Write-Host 'Only the known local account-link fields are removed.'
    Write-Host 'Keep ChatGPT, Codex and AI Switcher closed until this finishes.'
    if ((Read-Host 'Type REMOVE to unlink ALL listed local projects, or Enter to cancel') -cne 'REMOVE') { Write-Host 'Cancelled. Nothing changed.'; exit 0 }
    $backup = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('AI-Switcher-Unlink-Backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    Write-Host ('Backup folder: ' + $backup)
    [void][LocalAccountUnlink]::Apply($plan,$backup,$true)
    Write-Host ''
    Write-Host 'DONE. Local project account associations were removed.' -ForegroundColor Green
    Write-Host 'Open the intended account in AI Switcher, then open the original local chat.'
    Write-Host 'To undo: run this BAT again, choose 2 and paste the backup folder.'
    Write-Host ('Backup: ' + $backup)
    exit 0
} catch {
    $errorValue = $_.Exception
    while (($errorValue -is [System.Management.Automation.MethodInvocationException] -or $errorValue -is [System.Reflection.TargetInvocationException]) -and $errorValue.InnerException) { $errorValue = $errorValue.InnerException }
    Write-Host ''
    Write-Host ('STOPPED: ' + $errorValue.Message) -ForegroundColor Red
    Write-Host 'No processes were killed. If a backup path was shown, keep that folder.'
    exit 1
}
