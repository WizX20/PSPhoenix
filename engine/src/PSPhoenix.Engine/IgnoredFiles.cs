namespace PSPhoenix.Engine;

/// <summary>Why a gitignored file is left out unless the review includes it by name or pattern.</summary>
public enum CandidateFilter
{
    /// <summary>Not filtered: a candidate for the review.</summary>
    None,

    /// <summary>Generated code or an ignored lock file: the project's tooling makes it again.</summary>
    Generated,

    /// <summary>A log, a temporary or editor swap file, a folder view file.</summary>
    Noise,

    /// <summary>A binary file by its extension.</summary>
    Binary,

    /// <summary>Larger than the size cap (<c>files.maxKB</c>).</summary>
    Large,
}

/// <summary>A gitignored file in a repository.</summary>
/// <param name="Path">Relative to the repository, with <c>/</c>.</param>
/// <param name="Size">In bytes.</param>
/// <param name="SecretName">Its name says it holds a secret (<c>.env</c>, <c>*.pfx</c>, a per-repository secret pattern): stored only encrypted.</param>
/// <param name="Filter">Why it is left out unless the review includes it; <see cref="CandidateFilter.None"/> for a candidate.</param>
public sealed record IgnoredFile(string Path, long Size, bool SecretName, CandidateFilter Filter);

/// <summary>The gitignored files of a repository.</summary>
/// <param name="Files">In path order.</param>
/// <param name="Truncated">The walk stopped at <see cref="IgnoredFiles.MaxFiles"/>: an ignored folder holds more than a backup should look at.</param>
public sealed record IgnoredFileList(IReadOnlyList<IgnoredFile> Files, bool Truncated);

/// <summary>
/// The gitignored files of a repository that might be worth a backup (docs/design.md -> Gitignored
/// files: filters and review). Git lists them - <c>git ls-files --others --ignored --exclude-standard
/// --directory</c>, where an ignored folder is one entry - and this walks those folders and applies
/// the built-in filters:
/// <list type="bullet">
/// <item>the path-segment denylist, on every segment of every path - a leftover untracked folder can
/// hide <c>bin/</c> deep inside - and a folder that is a repository or a Python virtual environment of
/// its own: never entered, never listed;</item>
/// <item>generated code and lock files, logs and temporary files, binary extensions, and the size cap:
/// listed with their <see cref="CandidateFilter"/>, left out unless the review includes them;</item>
/// <item>secret classification by name.</item>
/// </list>
/// Links are not followed.
/// </summary>
public static class IgnoredFiles
{
    /// <summary>The most files one repository's walk looks at.</summary>
    public const int MaxFiles = 20000;

    /// <summary>Folders never entered, whatever their depth: build output, package caches, IDE state.</summary>
    public static IReadOnlyList<string> DeniedSegments { get; } =
    [
        "bin", "obj", "node_modules", "packages", ".packages", ".nuget", "dist", "out", "build", "artifacts",
        "publish", ".vs", ".idea", ".dart_tool", ".gradle", ".venv", "venv", "__pycache__", ".terraform",
        ".next", ".nuxt", ".angular", ".cache", "coverage", "TestResults", ".git",
    ];

    /// <summary>Folder paths never entered at any depth: Claude Code's worktrees.</summary>
    public static IReadOnlyList<string> DeniedFolders { get; } = [".claude/worktrees"];

    /// <summary>Generated code and ignored lock files.</summary>
    public static IReadOnlyList<string> GeneratedNames { get; } =
    [
        "*.g.dart", "*.freezed.dart", "*.mocks.dart", "*.g.cs", "*.g.i.cs", "GeneratedPluginRegistrant.*",
        "gradle-wrapper.jar", "gradle-wrapper.properties", "gradlew", "gradlew.bat",
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "packages.lock.json", "pubspec.lock", "Podfile.lock",
        "poetry.lock", "Pipfile.lock", "Cargo.lock", "composer.lock", "Gemfile.lock", "go.sum",
    ];

    /// <summary>Logs, temporary and swap files, folder view files.</summary>
    public static IReadOnlyList<string> NoiseNames { get; } =
    [
        "*.log", "*.tmp", "*.temp", "*.swp", "*.swo", "*~", "*.bak", ".DS_Store", "Thumbs.db", "desktop.ini",
        "*.suo", "*.cache",
    ];

    /// <summary>Extensions of binary files.</summary>
    public static IReadOnlyList<string> BinaryExtensions { get; } =
    [
        ".dll", ".exe", ".pdb", ".so", ".dylib", ".a", ".lib", ".o", ".class", ".jar", ".war", ".pyc", ".wasm",
        ".zip", ".7z", ".rar", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".nupkg", ".snupkg", ".msi", ".iso", ".dmg",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".tif", ".tiff", ".psd",
        ".mp3", ".mp4", ".mov", ".avi", ".wav", ".flac", ".ogg", ".webm", ".pdf",
        ".woff", ".woff2", ".ttf", ".otf", ".eot",
        ".db", ".sqlite", ".sqlite3", ".mdf", ".ldf", ".apk", ".aab", ".ipa",
    ];

    /// <summary>Names of files that hold a secret by their nature.</summary>
    public static IReadOnlyList<string> SecretNames { get; } =
        [".env", ".env.*", "secrets.*", "*.pfx", "*.p12", "*.pem", "*.key", "id_*"];

    private static readonly PathPattern[] Generated = [.. GeneratedNames.Select(PathPattern.Parse)];
    private static readonly PathPattern[] Noise = [.. NoiseNames.Select(PathPattern.Parse)];
    private static readonly PathPattern[] Secret = [.. SecretNames.Select(PathPattern.Parse)];
    private static readonly HashSet<string> Denied = new(DeniedSegments, StringComparer.OrdinalIgnoreCase);
    private static readonly HashSet<string> Binary = new(BinaryExtensions, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The files behind git's entries for <paramref name="repository"/>: each entry is a path relative
    /// to it, a folder one ending in <c>/</c>.
    /// </summary>
    /// <param name="repository">The repository's full path.</param>
    /// <param name="entries">What git listed.</param>
    /// <param name="maxBytes">The size cap: a larger file is <see cref="CandidateFilter.Large"/>.</param>
    /// <param name="secretPatterns">The repository's own secret patterns, on top of <see cref="SecretNames"/>.</param>
    public static IgnoredFileList List(string repository, IEnumerable<string> entries, long maxBytes, IEnumerable<string>? secretPatterns = null)
    {
        AtomicFile.RequireFullPath(repository);
        ArgumentNullException.ThrowIfNull(entries);
        PathPattern[] own = [.. (secretPatterns ?? []).Select(PathPattern.Parse)];
        List<IgnoredFile> files = [];
        bool truncated = false;
        foreach (string raw in entries)
        {
            string entry = PathPattern.Normalize(raw).Trim('/');
            if (entry.Length == 0 || IsDenied(entry) || entry.Split('/').Any(s => s is "." or ".."))
            {
                continue;
            }
            string full = Path.GetFullPath(Path.Combine(repository, entry));
            if (raw.EndsWith('/') || raw.EndsWith('\\') || Directory.Exists(full))
            {
                if (!Walk(full, entry, files, maxBytes, own))
                {
                    truncated = true;
                    break;
                }
            }
            else if (!Add(full, entry, files, maxBytes, own))
            {
                truncated = true;
                break;
            }
        }
        files.Sort((a, b) => string.CompareOrdinal(a.Path, b.Path));
        return new IgnoredFileList(files, truncated);
    }

    /// <summary>Whether a path lies in a folder the walk never enters.</summary>
    public static bool IsDenied(string path)
    {
        string normalized = PathPattern.Normalize(path).Trim('/');
        string[] segments = normalized.Split('/');
        // The last segment of a file is its name, not a folder - but a folder named like a denied one
        // is denied as a whole, so every segment counts.
        if (segments.Any(Denied.Contains))
        {
            return true;
        }
        string padded = "/" + normalized + "/";
        return DeniedFolders.Any(f => padded.Contains("/" + f + "/", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Whether a file name says the file holds a secret.</summary>
    public static bool IsSecretName(string name) => Secret.Any(p => p.IsMatch(Path.GetFileName(PathPattern.Normalize(name))));

    private static bool Walk(string folder, string relative, List<IgnoredFile> files, long maxBytes, PathPattern[] own)
    {
        Stack<(string Full, string Relative)> pending = new();
        pending.Push((folder, relative));
        while (pending.Count > 0)
        {
            (string full, string rel) = pending.Pop();
            if (!Enterable(full))
            {
                continue;
            }
            IEnumerable<string> children;
            try
            {
                children = [.. Directory.EnumerateFileSystemEntries(full)];
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (string child in children)
            {
                string name = Path.GetFileName(child);
                string childRel = rel + "/" + name;
                if (IsDenied(childRel))
                {
                    continue;
                }
                if (Directory.Exists(child))
                {
                    pending.Push((child, childRel));
                }
                else if (!Add(child, childRel, files, maxBytes, own))
                {
                    return false;
                }
            }
        }
        return true;
    }

    // A folder the walk enters: not a link, not a repository or a worktree of its own (its files are
    // its own repository's business), not a Python virtual environment.
    private static bool Enterable(string folder)
    {
        try
        {
            DirectoryInfo info = new(folder);
            if (!info.Exists || (info.Attributes.HasFlag(FileAttributes.ReparsePoint) && info.LinkTarget is not null))
            {
                return false;
            }
            return !Directory.Exists(Path.Combine(folder, ".git")) && !File.Exists(Path.Combine(folder, ".git"))
                && !File.Exists(Path.Combine(folder, "pyvenv.cfg"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool Add(string full, string relative, List<IgnoredFile> files, long maxBytes, PathPattern[] own)
    {
        if (files.Count >= MaxFiles)
        {
            return false;
        }
        FileInfo info = new(full);
        try
        {
            if (!info.Exists || info.LinkTarget is not null)
            {
                return true;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return true;
        }
        string name = info.Name;
        bool secret = IsSecretName(name) || own.Any(p => p.IsMatch(relative));
        CandidateFilter filter = CandidateFilter.None;
        if (Generated.Any(p => p.IsMatch(name)))
        {
            filter = CandidateFilter.Generated;
        }
        else if (Noise.Any(p => p.IsMatch(name)))
        {
            filter = CandidateFilter.Noise;
        }
        else if (!secret && Binary.Contains(info.Extension))
        {
            filter = CandidateFilter.Binary;
        }
        else if (info.Length > maxBytes)
        {
            filter = CandidateFilter.Large;
        }
        files.Add(new IgnoredFile(relative, info.Length, secret, filter));
        return true;
    }
}
