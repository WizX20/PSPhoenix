namespace PSPhoenix.Engine;

/// <summary>Where a restored file goes, which decides what may be written there.</summary>
public enum RestoreScope
{
    /// <summary>A gitignored file into a repository: anywhere in it but <c>.git</c> and a repository of its own.</summary>
    Repository,

    /// <summary>A file of <c>~/.claude</c>: only the selection the claude provider backs up.</summary>
    ClaudeHome,

    /// <summary>A project's file under <c>~/.claude/projects/&lt;name&gt;</c>: its memory, and its transcripts.</summary>
    ClaudeProject,
}

/// <summary>What restoring one file did.</summary>
public enum RestoreOutcome
{
    /// <summary>It was not there and was written (or would be, in a dry run).</summary>
    Restored,

    /// <summary>It was there, the same.</summary>
    Present,

    /// <summary>It was there, different - left as it is.</summary>
    Differs,

    /// <summary>It is encrypted and the restore has no age key.</summary>
    Skipped,
}

/// <summary>One file a restore looked at.</summary>
/// <param name="Target">Where it goes.</param>
/// <param name="Outcome">What happened.</param>
public sealed record RestoreResult(string Target, RestoreOutcome Outcome);

/// <summary>
/// Writes a snapshot's files back (docs/design.md -> A snapshot is trusted input): only where
/// PSPhoenix itself would have read them from, never over a file that is there. A manifest path
/// is refused when it is not a plain relative path - rooted, <c>..</c>, a Windows stream, device
/// or 8.3 name - when it leads into <c>.git</c>, and when it lies outside what its provider backs
/// up. Writing refuses a link on the way and a nested repository, and creates the file only when
/// it is not there: one that appears in the meantime is compared, not overwritten.
/// </summary>
public static class RestorePlanner
{
    /// <summary>The files at the top of <c>~/.claude</c> the claude provider backs up, besides <c>statusline*</c>.</summary>
    public static IReadOnlyList<string> ClaudeHomeFiles { get; } = ["settings.json", "CLAUDE.md", "keybindings.json"];

    /// <summary>The folders of <c>~/.claude</c> the claude provider backs up.</summary>
    public static IReadOnlyList<string> ClaudeHomeFolders { get; } = ["skills", "commands", "agents"];

    /// <summary>Folders a tool fills inside a skill: the claude provider skips them.</summary>
    public static IReadOnlyList<string> ClaudeSkipped { get; } = ["node_modules", ".git", ".venv", "venv", "__pycache__"];

    private static readonly HashSet<string> DeviceNames = new(
        ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³",
         .. Enumerable.Range(0, 10).SelectMany(n => new[] { $"COM{n}", $"LPT{n}" })],
        StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Why <paramref name="relative"/> may not be written in <paramref name="scope"/>, or nothing
    /// when it may.
    /// </summary>
    public static string? Refusal(string relative, RestoreScope scope)
    {
        if (PlainRefusal(relative) is { } plain)
        {
            return plain;
        }
        string[] segments = relative.Split('/');
        return scope switch
        {
            RestoreScope.Repository => null,
            RestoreScope.ClaudeHome => ClaudeHomeRefusal(segments),
            RestoreScope.ClaudeProject => ClaudeProjectRefusal(segments),
            _ => throw new ArgumentOutOfRangeException(nameof(scope)),
        };
    }

    /// <summary>
    /// The full path of <paramref name="relative"/> below <paramref name="folder"/> - <c>.</c> is the
    /// folder itself - when it is a plain relative path that stays inside it.
    /// </summary>
    /// <exception cref="InvalidDataException">It is not.</exception>
    public static string Below(string folder, string relative)
    {
        AtomicFile.RequireFullPath(folder);
        ArgumentNullException.ThrowIfNull(relative);
        string full = Path.GetFullPath(folder);
        if (relative == ".")
        {
            return full;
        }
        if (PlainRefusal(relative) is { } refusal)
        {
            throw new InvalidDataException($"{relative}: {refusal} - refused");
        }
        string path = Path.GetFullPath(Path.Combine(full, relative));
        string prefix = Path.TrimEndingDirectorySeparator(full) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(prefix, PathComparison.Comparison))
        {
            throw new InvalidDataException($"{relative} leads out of {folder} - refused");
        }
        return path;
    }

    /// <summary>
    /// Restores one file of a manifest: from <paramref name="sourceFolder"/>/<c>Stored</c> to
    /// <paramref name="targetFolder"/>/<paramref name="prefix"/>/<c>Path</c>, decrypted with
    /// <paramref name="identity"/> when it is stored encrypted. Written only when nothing is there.
    /// </summary>
    /// <param name="sourceFolder">The manifest's folder for it in the snapshot.</param>
    /// <param name="file">The file.</param>
    /// <param name="targetFolder">Where the scope begins: the repository, or Claude Code's folder.</param>
    /// <param name="prefix">Below <paramref name="targetFolder"/>, before the file's path: <c>projects/&lt;name&gt;</c> for a project, else empty.</param>
    /// <param name="scope">What may be written.</param>
    /// <param name="identity">The age identity of the restore, or nothing (empty: PowerShell passes <c>$null</c> as that).</param>
    /// <param name="dryRun">Look, write nothing.</param>
    /// <exception cref="InvalidDataException">A path is refused, or the snapshot lacks the file.</exception>
    public static RestoreResult Restore(string sourceFolder, ManifestFile file, string targetFolder, string prefix, RestoreScope scope, string? identity, bool dryRun)
    {
        ArgumentNullException.ThrowIfNull(file);
        ArgumentNullException.ThrowIfNull(prefix);
        string relative = prefix.Length == 0 ? file.Path : prefix + "/" + file.Path;
        if (Refusal(relative, scope) is { } refusal)
        {
            throw new InvalidDataException($"{relative}: {refusal} - refused");
        }
        if (file.Encrypted && !string.Equals(file.Stored, file.Path + ".age", StringComparison.Ordinal))
        {
            throw new InvalidDataException($"{relative}: stored as {file.Stored}, which is not its name or its name with .age - refused");
        }
        string target = Below(targetFolder, relative);
        string source = Below(sourceFolder, file.Stored);
        if (!File.Exists(source))
        {
            throw new InvalidDataException($"{file.Stored} is missing from the snapshot");
        }
        if (file.Encrypted && string.IsNullOrEmpty(identity))
        {
            return new RestoreResult(target, RestoreOutcome.Skipped);
        }
        byte[] bytes = File.ReadAllBytes(source);
        if (file.Encrypted)
        {
            bytes = Age.Decrypt(bytes, identity!);
        }
        if (!PrepareFolders(targetFolder, relative, scope, dryRun))
        {
            return new RestoreResult(target, RestoreOutcome.Restored);
        }
        if (Existing(target, bytes) is { } there)
        {
            return new RestoreResult(target, there);
        }
        if (dryRun)
        {
            return new RestoreResult(target, RestoreOutcome.Restored);
        }
        string temporary = AtomicFile.TemporaryPath(target);
        try
        {
            File.WriteAllBytes(temporary, bytes);
            // Create, never replace: a file that appeared since the look above is compared instead.
            File.Move(temporary, target, overwrite: false);
            return new RestoreResult(target, RestoreOutcome.Restored);
        }
        catch (IOException) when (File.Exists(target))
        {
            return new RestoreResult(target, Existing(target, bytes) ?? RestoreOutcome.Differs);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    /// <summary>
    /// Walks the folders from <paramref name="targetFolder"/> to the file's: a link on the way, or a
    /// repository of its own inside a repository, is refused; a missing folder is created. False in a
    /// dry run once a folder is missing - nothing below it can be there.
    /// </summary>
    private static bool PrepareFolders(string targetFolder, string relative, RestoreScope scope, bool dryRun)
    {
        string current = Path.GetFullPath(targetFolder);
        if (!Directory.Exists(current))
        {
            if (scope == RestoreScope.Repository)
            {
                throw new DirectoryNotFoundException($"{current} not found");
            }
            if (dryRun)
            {
                return false;
            }
            Directory.CreateDirectory(current);
        }
        string[] segments = relative.Split('/');
        for (int i = 0; i < segments.Length - 1; i++)
        {
            current = Path.Combine(current, segments[i]);
            if (Directory.Exists(current))
            {
                if (new DirectoryInfo(current).LinkTarget is not null)
                {
                    throw new InvalidDataException($"{relative}: {current} is a link - refused");
                }
                if (scope == RestoreScope.Repository && Path.Exists(Path.Combine(current, ".git")))
                {
                    throw new InvalidDataException($"{relative}: {current} is a repository of its own - refused");
                }
            }
            else if (Path.Exists(current))
            {
                throw new InvalidDataException($"{relative}: {current} is a file, not a folder");
            }
            else if (dryRun)
            {
                return false;
            }
            else
            {
                Directory.CreateDirectory(current);
            }
        }
        return true;
    }

    /// <summary>What is at <paramref name="target"/> compared with <paramref name="bytes"/>; nothing when nothing is.</summary>
    private static RestoreOutcome? Existing(string target, byte[] bytes)
    {
        if (Directory.Exists(target))
        {
            throw new InvalidDataException($"{target} is a folder - refused");
        }
        if (!File.Exists(target))
        {
            return null;
        }
        if (new FileInfo(target).LinkTarget is not null)
        {
            throw new InvalidDataException($"{target} is a link - refused");
        }
        return File.ReadAllBytes(target).AsSpan().SequenceEqual(bytes) ? RestoreOutcome.Present : RestoreOutcome.Differs;
    }

    /// <summary>Why a manifest path is no plain relative path with <c>/</c>, or nothing.</summary>
    private static string? PlainRefusal(string relative)
    {
        if (string.IsNullOrEmpty(relative))
        {
            return "an empty path";
        }
        if (relative.StartsWith('/') || Path.IsPathRooted(relative))
        {
            return "not a relative path";
        }
        if (relative.Contains('\\') || relative.Contains('\0'))
        {
            return "not a path with /";
        }
        foreach (string segment in relative.Split('/'))
        {
            if (segment is "" or "." or "..")
            {
                return "not a plain path (empty, . or .. in it)";
            }
            if (IsGit(segment))
            {
                return "inside .git";
            }
            if (OperatingSystem.IsWindows() && WindowsRefusal(segment) is { } windows)
            {
                return windows;
            }
        }
        return null;
    }

    /// <summary>
    /// <c>.git</c> in any case, and on Windows also as the file system would read it: with dots or
    /// spaces after it, or as its 8.3 short name <c>GIT~1</c>.
    /// </summary>
    private static bool IsGit(string segment)
    {
        string name = OperatingSystem.IsWindows() ? segment.TrimEnd('.', ' ') : segment;
        return name.Equals(".git", StringComparison.OrdinalIgnoreCase)
            || (OperatingSystem.IsWindows() && name.StartsWith("GIT~", StringComparison.OrdinalIgnoreCase) && name.Length > 4 && name[4..].All(char.IsAsciiDigit));
    }

    private static string? WindowsRefusal(string segment)
    {
        if (segment.IndexOfAny([':', '<', '>', '"', '|', '?', '*']) >= 0 || segment.Any(char.IsControl))
        {
            return "a name Windows reads differently (a stream, a drive or a wildcard)";
        }
        if (segment.EndsWith('.') || segment.EndsWith(' '))
        {
            return "a name ending in a dot or a space";
        }
        string stem = segment.Split('.')[0].TrimEnd(' ');
        if (DeviceNames.Contains(stem))
        {
            return "a Windows device name";
        }
        return null;
    }

    private static string? ClaudeHomeRefusal(string[] segments)
    {
        const string outside = "not a file the claude provider backs up";
        if (segments.Length == 1)
        {
            string name = segments[0];
            bool known = ClaudeHomeFiles.Contains(name, StringComparer.OrdinalIgnoreCase)
                || name.StartsWith("statusline", StringComparison.OrdinalIgnoreCase);
            return known ? null : outside;
        }
        if (!ClaudeHomeFolders.Contains(segments[0], StringComparer.OrdinalIgnoreCase))
        {
            return outside;
        }
        return segments.Any(s => ClaudeSkipped.Contains(s, StringComparer.OrdinalIgnoreCase)) ? outside : null;
    }

    private static string? ClaudeProjectRefusal(string[] segments)
    {
        const string outside = "not a project file the claude provider backs up";
        // projects/<name>/memory/<...>, or projects/<name>/<transcript>.jsonl
        if (segments.Length < 3 || segments[0] != "projects" || !IsProjectName(segments[1]))
        {
            return outside;
        }
        if (segments.Length == 3)
        {
            return segments[2].EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) ? null : outside;
        }
        return segments[2] == "memory" && !segments.Skip(3).Any(s => ClaudeSkipped.Contains(s, StringComparer.OrdinalIgnoreCase)) ? null : outside;
    }

    /// <summary>A folder name Claude Code makes from a path: letters, digits and dashes.</summary>
    public static bool IsProjectName(string name) =>
        name.Length > 0 && name.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');
}
