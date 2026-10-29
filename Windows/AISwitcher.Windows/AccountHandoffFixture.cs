using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static partial class PreviewRunner {
    // Explicit, disposable CI fixture: fake ChatGPT identities and loopback-only model responses.
    static async Task AccountHandoffAsync(string root,string output,string cli){
        var source=Path.Combine(root,"shared-history");Directory.CreateDirectory(source);
        var project=Path.Combine(root,"Project A");Directory.CreateDirectory(project);
        var repo=new Repository(Path.Combine(root,"manager"),Path.Combine(root,"backends"));
        var a=new Account{Name="Fixture account 1",SharesLocalWorkspace=true};var b=new Account{Name="Fixture account 2",SharesLocalWorkspace=true};
        repo.Save(new(){Accounts=[a,b]});var prefs=new Preferences();prefs.Executables["workspace"]=source;
        foreach(var account in new[]{a,b}){repo.PrepareQuota(account);repo.PrepareProfile(account);}
        await SharedWorkspace.PrepareAsync(a,repo,prefs);
        using var mock=new HandoffResponses();await using(var first=await HandoffRpc.Create(cli,repo,a,prefs,mock.Url,"one")){
            var linked=await first.Call("project/create",new{idempotencyKey="fixture-local-project",name="Project A",roots=new[]{new{path=project}},metadata=new Dictionary<string,string>{{"codex.localProjectId","fixture-local-project"},{"codex.chatGptBacking","{\"accountId\":\"fixture-account-one\",\"userId\":\"fixture-user-one\",\"projectId\":\"g-p-fixture\"}"},{"fixture.keep","preserved"}}});
            File.WriteAllText(Path.Combine(root,"source-project-id"),linked.GetProperty("project").GetProperty("id").GetString());
            var started=await first.Call("thread/start",new{model="fixture-model",cwd=project});var id=started.GetProperty("thread").GetProperty("id").GetString()!;
            await first.Call("turn/start",new{threadId=id,input=new[]{new{type="text",text="Fictional account handoff regression. Reply with fixture text only."}}});
            var completed=await first.WaitTurn();Require(completed.GetProperty("turn").GetProperty("status").GetString()=="failed","Fixture account 1 did not hit its simulated quota");
            await first.Call("thread/metadata/update",new{threadId=id,projectId=linked.GetProperty("project").GetProperty("id").GetString()});
            await first.Call("account/logout",null);File.WriteAllText(Path.Combine(root,"source-thread-id"),id);
        }
        SharedWorkspace.Archive(a,repo);
        var thread=File.ReadAllText(Path.Combine(root,"source-thread-id"));
        await SharedWorkspace.PrepareAsync(b,repo,prefs);
        await using(var second=await HandoffRpc.Create(cli,repo,b,prefs,mock.Url,"two")){
            // The loopback Responses server checks the real outgoing account header.
            // Avoid account/read here: native routing discovery requires an HTTPS
            // service origin, whereas this fixture must stay entirely on loopback.
            var original=await second.Call("thread/read",new{threadId=thread});var oldSession=original.GetProperty("thread").GetProperty("sessionId").GetString();
            var projectId=File.ReadAllText(Path.Combine(root,"source-project-id"));var localProject=(await second.Call("project/read",new{projectId})).GetProperty("project");
            Require(localProject.GetProperty("id").GetString()==projectId&&localProject.GetProperty("metadata").GetProperty("fixture.keep").GetString()=="preserved"&&!localProject.GetProperty("metadata").TryGetProperty("codex.chatGptBacking",out _),"Local project account binding was retained or unrelated metadata changed");
            var resumed=await second.Call("thread/resume",new{threadId=thread,excludeTurns=true});
            Require(resumed.GetProperty("thread").GetProperty("id").GetString()==thread&&resumed.GetProperty("thread").GetProperty("sessionId").GetString()==oldSession,"The original conversation or session ID changed");
            Require(resumed.GetProperty("thread").GetProperty("projectId").GetString()==projectId,"The conversation left its original project");
            Require(NativePlatform.SamePath(resumed.GetProperty("cwd").GetString()!,project),"Handoff changed the project working directory");
            await second.Call("turn/start",new{threadId=thread,input=new[]{new{type="text",text="Continue the fictional project using this account."}}});
            var completed=await second.WaitTurn();Require(completed.GetProperty("turn").GetProperty("status").GetString()=="completed","Account 2 could not continue the original conversation against loopback Responses");
            var history=await second.Call("thread/turns/list",new{threadId=thread,itemsView="full",limit=10});Require(history.GetProperty("data").GetArrayLength()>=2,"Previous conversation history was lost");
            var preserved=await second.Call("thread/read",new{threadId=thread});Require(preserved.GetProperty("thread").GetProperty("id").GetString()==thread&&preserved.GetProperty("thread").GetProperty("sessionId").GetString()==oldSession,"The original conversation was replaced");
        }
        Require(mock.FirstAccountRejected&&mock.SecondAccountAccepted,"The real CLI did not send each turn with the correct fictional account");
        SharedWorkspace.Archive(b,repo);
        File.WriteAllText(Path.Combine(output,"account-handoff-result.txt"),"PASS: real native Windows Codex; two private fictional ChatGPT identities; loopback-only quota failure for account 1; logout and close account 1; detach native local project account metadata automatically; resume the SAME conversation/project/session ID under account 2 without selecting or forking; subsequent Responses request authenticates as account 2 and completes; source/target authentication stays separate. No real account or external model call.\n");
    }
    sealed class HandoffRpc:IAsyncDisposable {
        readonly StdioTransport transport;readonly Queue<JsonElement> notifications=[];int id;
        HandoffRpc(StdioTransport transport){this.transport=transport;}
        public static async Task<HandoffRpc> Create(string cli,Repository repo,Account account,Preferences prefs,string url,string which){
            var env=ChildEnvironment.Create(NativePlatform.EnvironmentValues(),repo.QuotaHome(account));env["CODEX_SQLITE_HOME"]=SharedWorkspace.BoundDatabase(account,repo,prefs);
            var args=new[]{"app-server","--listen","stdio://","-c","analytics.enabled=false","-c","chatgpt_base_url="+JsonSerializer.Serialize(url),"-c","model_provider=\"fixture\"","-c","model_providers.fixture.name=\"Fixture\"","-c","model_providers.fixture.base_url="+JsonSerializer.Serialize(url+"/v1"),"-c","model_providers.fixture.wire_api=\"responses\"","-c","model_providers.fixture.requires_openai_auth=true","-c","model_providers.fixture.supports_websockets=false"};
            var value=new HandoffRpc(new StdioTransport(ChildEnvironment.StartInfo(cli,args,env,repo.Root)));
            try{
                await value.Call("initialize",new{clientInfo=new{name="ai_switcher_account_fixture",version="1"},capabilities=new{experimentalApi=true}});
                await value.transport.SendAsync("{\"method\":\"initialized\"}",CancellationToken.None);
                static string Encode(object data)=>Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(data)).TrimEnd('=').Replace('+','-').Replace('/','_');
                var token=Encode(new{alg="RS256"})+"."+Encode(new Dictionary<string,object>{{"sub","fixture-user-"+which},{"email","fixture-"+which+"@example.test"},{"exp",DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()},{"https://api.openai.com/auth",new{chatgpt_account_id="fixture-account-"+which,chatgpt_user_id="fixture-user-"+which,chatgpt_plan_type="plus"}}})+".fixture";
                await value.Call("account/login/start",new{type="chatgptAuthTokens",accessToken=token,chatgptAccountId="fixture-account-"+which,chatgptPlanType="plus"});return value;
            }catch{await value.DisposeAsync();throw;}
        }
        async Task<JsonElement> Read(CancellationToken ct){var line=await transport.ReadAsync(ct)??throw new InvalidOperationException("Native handoff fixture closed");using var doc=JsonDocument.Parse(line);return doc.RootElement.Clone();}
        public async Task<JsonElement> Call(string method,object? parameters){
            var next=++id;using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(60));
            await transport.SendAsync(JsonSerializer.Serialize(new{id=next,method,@params=parameters}),timeout.Token);
            while(true){var message=await Read(timeout.Token);if(message.TryGetProperty("id",out var response)&&!message.TryGetProperty("method",out _)&&response.TryGetInt32(out var number)&&number==next){
                if(message.TryGetProperty("error",out var error))throw new InvalidOperationException(method+": "+error.GetRawText());return message.GetProperty("result");
            }notifications.Enqueue(message);}
        }
        public async Task<JsonElement> WaitTurn(){
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(60));
            while(true){var message=notifications.Count>0?notifications.Dequeue():await Read(timeout.Token);if(message.TryGetProperty("method",out var method)&&method.GetString()=="turn/completed")return message.GetProperty("params");}
        }
        public ValueTask DisposeAsync()=>transport.DisposeAsync();
    }
    sealed class HandoffResponses:IDisposable {
        readonly TcpListener listener=new(IPAddress.Loopback,0);readonly CancellationTokenSource lifetime=new();
        public string Url { get; }
        public bool FirstAccountRejected { get; private set; }
        public bool SecondAccountAccepted { get; private set; }
        public HandoffResponses(){listener.Start();Url="http://127.0.0.1:"+((IPEndPoint)listener.LocalEndpoint).Port;_=Serve();}
        async Task Serve(){try{while(!lifetime.IsCancellationRequested){var client=await listener.AcceptTcpClientAsync(lifetime.Token);_=Handle(client);}}catch(OperationCanceledException){}catch(ObjectDisposedException){} }
        async Task Handle(TcpClient client){using(client)try{
            var stream=client.GetStream();using var header=new MemoryStream();var tail="";
            while(header.Length<65536){var b=new byte[1];if(await stream.ReadAsync(b,lifetime.Token)==0)return;header.WriteByte(b[0]);tail=(tail+(char)b[0]);if(tail.Length>4)tail=tail[^4..];if(tail=="\r\n\r\n")break;}
            var lines=Encoding.ASCII.GetString(header.ToArray()).Split("\r\n");var headers=lines.Skip(1).Where(x=>x.Contains(':')).Select(x=>x.Split(':',2)).ToDictionary(x=>x[0].Trim(),x=>x[1].Trim(),StringComparer.OrdinalIgnoreCase);
            var length=int.TryParse(headers.GetValueOrDefault("Content-Length"),out var size)?size:0;if(length<0||length>8_388_608)return;
            var body=new byte[length];await stream.ReadExactlyAsync(body,lifetime.Token);
            var account=headers.GetValueOrDefault("ChatGPT-Account-Id");
            var responseRequest=lines[0].StartsWith("POST ",StringComparison.Ordinal)&&lines[0].Split(' ')[1].Contains("responses",StringComparison.Ordinal);
            string text,contentType="application/json",status="200 OK";
            if(responseRequest&&account=="fixture-account-one"){
                FirstAccountRejected=true;status="429 Too Many Requests";text="{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"Fixture account 1 quota exhausted\"}}";
            }else if(responseRequest&&account=="fixture-account-two"){
                SecondAccountAccepted=true;contentType="text/event-stream";
                var item=new{id="msg_fixture",type="message",role="assistant",status="completed",content=new[]{new{type="output_text",text="Fixture account 2 continued successfully.",annotations=Array.Empty<object>()}}};
                text="event: response.created\ndata: "+JsonSerializer.Serialize(new{type="response.created",response=new{id="resp_fixture",status="in_progress",output=Array.Empty<object>()}})+"\n\n";
                text+="event: response.output_item.done\ndata: "+JsonSerializer.Serialize(new{type="response.output_item.done",output_index=0,item})+"\n\n";
                text+="event: response.completed\ndata: "+JsonSerializer.Serialize(new{type="response.completed",response=new{id="resp_fixture",status="completed",output=new[]{item},usage=new{input_tokens=10,output_tokens=5,total_tokens=15}}})+"\n\n";
            }else if(responseRequest){status="401 Unauthorized";text="{\"error\":{\"message\":\"Fixture rejected unexpected identity\"}}";}
            else{text="{\"data\":[],\"models\":[],\"plan_type\":\"plus\",\"rate_limit\":{\"allowed\":true,\"limit_reached\":false,\"primary_window\":{\"used_percent\":0,\"limit_window_seconds\":18000,\"reset_at\":2000000000}}}";}
            var payload=Encoding.UTF8.GetBytes(text);var prefix=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+"\r\nContent-Type: "+contentType+"\r\nContent-Length: "+payload.Length+"\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(prefix,lifetime.Token);await stream.WriteAsync(payload,lifetime.Token);await stream.FlushAsync(lifetime.Token);
        }catch(OperationCanceledException){}catch(IOException){}catch(ObjectDisposedException){} }
        public void Dispose(){lifetime.Cancel();listener.Stop();lifetime.Dispose();}
    }
}
