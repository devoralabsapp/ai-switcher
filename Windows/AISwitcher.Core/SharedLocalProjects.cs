using System.Text.Json.Nodes;

namespace AISwitcher.Core;

/// Detach only native, folder-backed local projects. Cloud mirrors keep their owner.
public static class SharedLocalProjects {
    static readonly string[] ProjectLinks=["chatGptBacking","chatGptBackingCreation","retiredChatGptBacking","chatGptBackingRecoveryPending"];
    static readonly string[] DatabaseLinks=["codex.chatGptBacking","codex.chatGptBackingCreation","codex.retiredChatGptBacking"];
    public static bool IsLocal(string id,IEnumerable<string> roots){var paths=roots.ToArray();return !string.IsNullOrWhiteSpace(id)&&!id.StartsWith("g-p-",StringComparison.Ordinal)&&paths.Length>0&&paths.All(LocalRoot);}
    static bool LocalRoot(string path)=>Path.IsPathFullyQualified(path)&&!path.Replace('\\','/').Split('/').Contains(".chatgpt-projects",StringComparer.OrdinalIgnoreCase);
    public static JsonObject? DetachedMetadata(string id,JsonObject metadata,IEnumerable<string> roots){
        var localId=metadata["codex.localProjectId"]?.GetValue<string>()??id;
        var paths=roots.ToArray();if(!IsLocal(id,paths)||!IsLocal(localId,paths)||!DatabaseLinks.Any(metadata.ContainsKey))return null;
        var result=metadata.DeepClone().AsObject();foreach(var key in DatabaseLinks)result.Remove(key);return result;
    }
    // Mutates only the owned profile's projected UI state, never the source file.
    // Return the exact original entries so callers can save recovery data first.
    public static JsonObject DetachState(JsonObject state){
        var saved=new JsonObject();var detached=new HashSet<string>(StringComparer.Ordinal);
        if(state["local-projects"] is not JsonObject projects)return saved;
        foreach(var pair in projects){
            if(pair.Value is not JsonObject project||project["rootPaths"] is not JsonArray paths)continue;
            var roots=paths.Select(x=>x is JsonValue value&&value.TryGetValue<string>(out var path)?path:"").ToArray();
            var id=project["id"]?.GetValue<string>()??pair.Key;
            if(!IsLocal(pair.Key,roots)||!IsLocal(id,roots))continue;
            detached.Add(pair.Key);
            if(!ProjectLinks.Any(project.ContainsKey))continue;
            saved[pair.Key]=project.DeepClone();foreach(var key in ProjectLinks)project.Remove(key);
        }
        if(state["thread-project-assignments"] is JsonObject assignments)foreach(var pair in assignments){
            if(pair.Value is not JsonObject assignment||assignment["projectKind"]?.GetValue<string>()!="local"||assignment["projectId"]?.GetValue<string>() is not string id||!detached.Contains(id)||assignment["projectOrigin"]?.GetValue<string>()!="chatgpt")continue;
            if(saved["assignments"] is not JsonObject originals){originals=new JsonObject();saved["assignments"]=originals;}originals[pair.Key]=assignment.DeepClone();assignment.Remove("projectOrigin");
        }
        return saved;
    }
}
