using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PSPhoenix.Engine;

/// <summary>A scanned repository, as the MCP backup keys a project by it.</summary>
/// <param name="Identity">Its identity (<c>host/owner/name</c>).</param>
/// <param name="Root">The root it lies under.</param>
/// <param name="Path">Its path relative to the root.</param>
/// <param name="FullPath">Where it is.</param>
public sealed record McpRepository(string Identity, string Root, string Path, string FullPath);

/// <summary>The MCP servers of <c>~/.claude.json</c> as a backup holds them.</summary>
/// <param name="Json">The backup document: <c>mcpServers</c>, and <c>projects</c> by their key with the repository they belong to.</param>
/// <param name="Servers">How many servers it holds.</param>
public sealed record McpBackup(string Json, int Servers);

/// <summary>A project in an MCP backup.</summary>
/// <param name="Key">Its key in <c>~/.claude.json</c> where it was backed up: its path, with <c>/</c>.</param>
/// <param name="Identity">The repository it belongs to, or nothing.</param>
/// <param name="Root">That repository's root.</param>
/// <param name="Path">That repository's path relative to the root.</param>
public sealed record McpProject(string Key, string? Identity, string? Root, string? Path);

/// <summary>What restoring one MCP server did.</summary>
public enum McpOutcome
{
    /// <summary>It was not there and was added.</summary>
    Added,

    /// <summary>It was there, the same.</summary>
    Present,

    /// <summary>It was there, different - left as it is.</summary>
    Differs,
}

/// <summary>One MCP server a restore looked at.</summary>
/// <param name="Server">Its name.</param>
/// <param name="Where"><c>user</c>, or the project key it went under.</param>
/// <param name="Outcome">What happened.</param>
public sealed record McpChange(string Server, string Where, McpOutcome Outcome);

/// <summary>
/// The MCP servers of Claude Code's <c>~/.claude.json</c> (docs/design.md -> Snapshot layout): read
/// and merged as JSON nodes, never through a round trip that changes what it does not touch - keys
/// compared exactly (two projects whose paths differ only in case stay two), strings and numbers as
/// they were, no depth limit. A merge writes the file only when it adds something, and only when
/// Claude Code did not write it in the meantime.
/// </summary>
public static class ClaudeMcp
{
    private static readonly JsonSerializerOptions Indented = new()
    {
        WriteIndented = true,
        // As Claude Code writes it: non-ASCII as it is, not \u-escaped.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static readonly JsonNodeOptions ExactKeys = new() { PropertyNameCaseInsensitive = false };

    /// <summary>
    /// The MCP servers of <paramref name="claudeJsonPath"/> - the user's own and each project's - with
    /// each project matched to the repository at its path; nothing when there are none (or no file).
    /// </summary>
    public static McpBackup? Backup(string claudeJsonPath, IEnumerable<McpRepository> repositories)
    {
        AtomicFile.RequireFullPath(claudeJsonPath);
        ArgumentNullException.ThrowIfNull(repositories);
        if (!File.Exists(claudeJsonPath))
        {
            return null;
        }
        JsonObject root = ReadObject(claudeJsonPath, out _);
        McpRepository[] repos = [.. repositories];
        JsonObject user = root["mcpServers"] is JsonObject servers ? (JsonObject)servers.DeepClone() : [];
        int count = user.Count;
        JsonObject projects = [];
        if (root["projects"] is JsonObject all)
        {
            foreach ((string key, JsonNode? value) in all)
            {
                if (value?["mcpServers"] is not JsonObject own || own.Count == 0)
                {
                    continue;
                }
                JsonObject entry = [];
                McpRepository? repo = Array.Find(repos, r => SamePath(r.FullPath, key));
                if (repo is not null)
                {
                    entry["identity"] = repo.Identity;
                    entry["root"] = repo.Root;
                    entry["path"] = repo.Path;
                }
                entry["mcpServers"] = own.DeepClone();
                projects[key] = entry;
                count += own.Count;
            }
        }
        if (count == 0)
        {
            return null;
        }
        JsonObject document = new(ExactKeys) { ["mcpServers"] = user, ["projects"] = projects };
        return new McpBackup(document.ToJsonString(Indented), count);
    }

    /// <summary>The projects of an MCP backup, for the caller to map to their new keys.</summary>
    public static IReadOnlyList<McpProject> Projects(string backupJson)
    {
        JsonObject backup = ParseObject(backupJson);
        if (backup["projects"] is not JsonObject projects)
        {
            return [];
        }
        return [.. projects.Select(p => new McpProject(p.Key, Text(p.Value?["identity"]), Text(p.Value?["root"]), Text(p.Value?["path"])))];
    }

    /// <summary>
    /// Adds the servers of <paramref name="backupJson"/> that <paramref name="claudeJsonPath"/> lacks:
    /// the user's own, and each project's under the key <paramref name="projectKeys"/> maps it to (a
    /// project mapped to nothing is skipped). A server that is there is left as it is. Nothing else
    /// of the file changes. With <paramref name="dryRun"/> nothing is written.
    /// </summary>
    public static IReadOnlyList<McpChange> Merge(string claudeJsonPath, string backupJson, IReadOnlyDictionary<string, string?> projectKeys, bool dryRun)
    {
        AtomicFile.RequireFullPath(claudeJsonPath);
        ArgumentNullException.ThrowIfNull(projectKeys);
        JsonObject backup = ParseObject(backupJson);
        for (int attempt = 1; ; attempt++)
        {
            bool exists = File.Exists(claudeJsonPath);
            DateTime stamp = default;
            JsonObject root = exists ? ReadObject(claudeJsonPath, out stamp) : new JsonObject(ExactKeys);
            List<McpChange> changes = [];
            if (backup["mcpServers"] is JsonObject user)
            {
                MergeInto(Child(root, "mcpServers"), user, "user", changes);
            }
            if (backup["projects"] is JsonObject projects)
            {
                foreach ((string key, JsonNode? value) in projects)
                {
                    if (value?["mcpServers"] is not JsonObject servers || !projectKeys.TryGetValue(key, out string? target) || target is null)
                    {
                        continue;
                    }
                    MergeInto(Child(Child(Child(root, "projects"), target), "mcpServers"), servers, target, changes);
                }
            }
            if (dryRun || !changes.Any(c => c.Outcome == McpOutcome.Added))
            {
                return changes;
            }
            // Claude Code rewrites the file often: what it wrote since the read must not be lost.
            if (exists && File.GetLastWriteTimeUtc(claudeJsonPath) != stamp)
            {
                if (attempt >= 3)
                {
                    throw new IOException($"{claudeJsonPath} keeps changing while the MCP servers are restored - close Claude Code and try again");
                }
                continue;
            }
            AtomicFile.WriteAllText(claudeJsonPath, root.ToJsonString(Indented));
            return changes;
        }
    }

    private static void MergeInto(JsonObject into, JsonObject servers, string where, List<McpChange> changes)
    {
        foreach ((string name, JsonNode? server) in servers)
        {
            if (into.TryGetPropertyValue(name, out JsonNode? there))
            {
                bool same = (there?.ToJsonString() ?? "null") == (server?.ToJsonString() ?? "null");
                changes.Add(new McpChange(name, where, same ? McpOutcome.Present : McpOutcome.Differs));
                continue;
            }
            into[name] = server?.DeepClone();
            changes.Add(new McpChange(name, where, McpOutcome.Added));
        }
    }

    // The object under name, made when it is missing or not an object.
    private static JsonObject Child(JsonObject parent, string name)
    {
        if (parent[name] is JsonObject child)
        {
            return child;
        }
        JsonObject made = new(ExactKeys);
        parent[name] = made;
        return made;
    }

    private static JsonObject ReadObject(string path, out DateTime stamp)
    {
        stamp = File.GetLastWriteTimeUtc(path);
        byte[] bytes = SecretScanner.ReadShared(path);
        try
        {
            return JsonNode.Parse(bytes, ExactKeys) as JsonObject ?? throw new InvalidDataException($"{path} is not a JSON object");
        }
        catch (JsonException e)
        {
            throw new InvalidDataException($"{path} is not valid JSON: {e.Message}", e);
        }
    }

    private static JsonObject ParseObject(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        try
        {
            return JsonNode.Parse(json, ExactKeys) as JsonObject ?? throw new InvalidDataException("the MCP backup is not a JSON object");
        }
        catch (JsonException e)
        {
            throw new InvalidDataException($"the MCP backup is not valid JSON: {e.Message}", e);
        }
    }

    private static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    // ~/.claude.json keys a project by its path with /; the platform decides on case.
    private static bool SamePath(string fullPath, string key) =>
        string.Equals(fullPath.Replace('\\', '/').TrimEnd('/'), key.Replace('\\', '/').TrimEnd('/'), PathComparison.Comparison);
}
