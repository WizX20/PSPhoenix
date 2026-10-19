using System.Text.Json;

namespace PSPhoenix.Engine;

/// <summary>A file in a manifest: where it goes, and how the snapshot stores it.</summary>
/// <param name="Path">Its path relative to where it goes, with <c>/</c>.</param>
/// <param name="Stored">Its name in the snapshot: <paramref name="Path"/>, or <paramref name="Path"/><c>.age</c> when encrypted.</param>
public sealed record ManifestFile(string Path, string Stored)
{
    /// <summary>Whether the snapshot holds it encrypted.</summary>
    public bool Encrypted => !string.Equals(Stored, Path, StringComparison.Ordinal);
}

/// <summary>A repository in <c>repo-files/files.json</c>.</summary>
/// <param name="Identity">Its identity (<c>host/owner/name</c>).</param>
/// <param name="Root">The root it lay under.</param>
/// <param name="Path">Its path relative to the root, with <c>/</c>; <c>.</c> for the root itself.</param>
/// <param name="Folder">Its folder in the snapshot, relative to <c>repo-files</c>.</param>
/// <param name="Files">Its files.</param>
public sealed record RepoFilesEntry(string Identity, string Root, string Path, string Folder, IReadOnlyList<ManifestFile> Files);

/// <summary><c>repo-files/files.json</c>.</summary>
public sealed record RepoFilesManifest(int Format, IReadOnlyList<RepoFilesEntry> Repositories);

/// <summary>A project in <c>claude/claude-files.json</c>.</summary>
/// <param name="Name">Its folder under <c>~/.claude/projects</c> where it was backed up.</param>
/// <param name="Identity">The repository it belongs to, or nothing.</param>
/// <param name="Root">That repository's root.</param>
/// <param name="Path">That repository's path relative to the root.</param>
/// <param name="Folder">Its folder in the snapshot, relative to <c>claude/projects</c>.</param>
/// <param name="Files">Its files, relative to its project folder.</param>
public sealed record ClaudeProjectEntry(string Name, string? Identity, string? Root, string? Path, string Folder, IReadOnlyList<ManifestFile> Files);

/// <summary><c>claude/claude-files.json</c>.</summary>
/// <param name="Format">Its format.</param>
/// <param name="Home">The files of <c>~/.claude</c>, relative to it.</param>
/// <param name="Projects">The projects.</param>
/// <param name="ClaudeJson">How the MCP servers are stored - <c>claude.json</c> or <c>claude.json.age</c> - or nothing.</param>
public sealed record ClaudeManifest(int Format, IReadOnlyList<ManifestFile> Home, IReadOnlyList<ClaudeProjectEntry> Projects, string? ClaudeJson);

/// <summary>
/// The manifests a restore follows (docs/design.md -> Restore sequence), read strictly: every value
/// the type it must be, a format this version knows. A manifest that is not what PSPhoenix writes is
/// refused as a whole; whether each path in it may be written is <see cref="RestorePlanner"/>'s call.
/// </summary>
public static class RestoreManifest
{
    /// <summary>The format of <c>files.json</c> this version reads and writes.</summary>
    public const int RepoFilesFormat = 1;

    /// <summary>The format of <c>claude-files.json</c> this version reads and writes.</summary>
    public const int ClaudeFormat = 1;

    /// <summary>Reads <c>repo-files/files.json</c>.</summary>
    /// <exception cref="InvalidDataException">It is not JSON, not of a known format, or a value is not of its type.</exception>
    public static RepoFilesManifest ReadRepoFiles(string file)
    {
        using JsonDocument document = Parse(file);
        JsonElement root = document.RootElement;
        int format = Format(file, root, RepoFilesFormat);
        List<RepoFilesEntry> repositories = [];
        foreach ((JsonElement entry, string at) in Array(file, root, "repositories", "repositories"))
        {
            Object(file, entry, at);
            repositories.Add(new RepoFilesEntry(
                Text(file, entry, "identity", at)!,
                Text(file, entry, "root", at)!,
                Text(file, entry, "path", at)!,
                Text(file, entry, "folder", at)!,
                Files(file, entry, at)));
        }
        return new RepoFilesManifest(format, repositories);
    }

    /// <summary>Reads <c>claude/claude-files.json</c>.</summary>
    /// <exception cref="InvalidDataException">It is not JSON, not of a known format, or a value is not of its type.</exception>
    public static ClaudeManifest ReadClaude(string file)
    {
        using JsonDocument document = Parse(file);
        JsonElement root = document.RootElement;
        int format = Format(file, root, ClaudeFormat);
        List<ClaudeProjectEntry> projects = [];
        foreach ((JsonElement entry, string at) in Array(file, root, "projects", "projects"))
        {
            Object(file, entry, at);
            string? identity = Text(file, entry, "identity", at, optional: true);
            projects.Add(new ClaudeProjectEntry(
                Text(file, entry, "name", at)!,
                identity,
                Text(file, entry, "root", at, optional: identity is null),
                Text(file, entry, "path", at, optional: identity is null),
                Text(file, entry, "folder", at)!,
                Files(file, entry, at)));
        }
        List<ManifestFile> home = [.. Array(file, root, "home", "home").Select(f => File(file, f.Element, f.At))];
        return new ClaudeManifest(format, home, projects, Text(file, root, "claudeJson", "the document", optional: true));
    }

    private static JsonDocument Parse(string file)
    {
        AtomicFile.RequireFullPath(file);
        try
        {
            JsonDocument document = JsonDocument.Parse(System.IO.File.ReadAllBytes(file));
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                document.Dispose();
                throw new InvalidDataException($"{file} is not a PSPhoenix manifest");
            }
            return document;
        }
        catch (JsonException e)
        {
            throw new InvalidDataException($"{file} is not valid JSON: {e.Message}", e);
        }
    }

    private static int Format(string file, JsonElement root, int known)
    {
        if (!root.TryGetProperty("format", out JsonElement value) || !value.TryGetInt32(out int format) || format < 1)
        {
            throw new InvalidDataException($"{file} has no format - not a PSPhoenix manifest");
        }
        if (format > known)
        {
            throw new InvalidDataException($"{file} was written by a newer PSPhoenix (format {format}) - update PSPhoenix first");
        }
        return format;
    }

    private static List<(JsonElement Element, string At)> Array(string file, JsonElement parent, string name, string at)
    {
        // An empty list is left out by PowerShell's ConvertTo-Json at times: missing or null is none.
        if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind == JsonValueKind.Null)
        {
            return [];
        }
        if (value.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException($"{file}: {at} is not a list");
        }
        return [.. value.EnumerateArray().Select((e, i) => (e, $"{at}[{i}]"))];
    }

    private static void Object(string file, JsonElement value, string at)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException($"{file}: {at} is not an object");
        }
    }

    private static string? Text(string file, JsonElement parent, string name, string at, bool optional = false)
    {
        if (!parent.TryGetProperty(name, out JsonElement value) || value.ValueKind == JsonValueKind.Null)
        {
            return optional ? null : throw new InvalidDataException($"{file}: {at} has no {name}");
        }
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: > 0 } text)
        {
            throw new InvalidDataException($"{file}: {at}.{name} is not a text");
        }
        return text;
    }

    private static List<ManifestFile> Files(string file, JsonElement entry, string at) =>
        [.. Array(file, entry, "files", at + ".files").Select(f => File(file, f.Element, f.At))];

    private static ManifestFile File(string file, JsonElement value, string at)
    {
        Object(file, value, at);
        return new ManifestFile(Text(file, value, "path", at)!, Text(file, value, "stored", at)!);
    }
}
