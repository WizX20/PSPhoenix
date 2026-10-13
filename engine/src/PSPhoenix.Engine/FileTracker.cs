namespace PSPhoenix.Engine;

/// <summary>A source file as a run saw it: its size, its mtime (UTC ticks) and its SHA-256.</summary>
public sealed record FileStamp(long Size, long Mtime, string Sha256);

/// <summary>
/// Change detection for one provider (docs/design.md -> Change detection and resource use): the
/// files as its last successful run saw them (<see cref="Known"/>), and what this run sees
/// (<see cref="Seen"/>). The run keeps <see cref="Seen"/> only when the provider succeeds - a run
/// that failed half-way must not make a change look handled the next time - and a file the provider
/// no longer looks at drops out by itself. A provider gets one as <c>$Context.Files</c>.
/// </summary>
public sealed class FileTracker
{
    private readonly Func<string, string> hash;

    /// <summary>A tracker that starts from what the provider's last run saw (none: everything is new).</summary>
    public FileTracker(IReadOnlyDictionary<string, FileStamp>? known = null)
        : this(known, FileHash.Sha256)
    {
    }

    /// <summary>With the hash function given: the tests see which files it reads.</summary>
    internal FileTracker(IReadOnlyDictionary<string, FileStamp>? known, Func<string, string> hash)
    {
        Known = known ?? PathComparison.NewDictionary<FileStamp>();
        this.hash = hash;
    }

    /// <summary>The files as the provider's last successful run saw them, by full path.</summary>
    public IReadOnlyDictionary<string, FileStamp> Known { get; }

    /// <summary>The files this run looked at, by full path.</summary>
    public Dictionary<string, FileStamp> Seen { get; } = PathComparison.NewDictionary<FileStamp>();

    /// <summary>
    /// True when <paramref name="path"/> is new, or its content differs from what the last run saw.
    /// Size and mtime first - a stat, the cheap part - and the SHA-256 only when either differs, so a
    /// file touched but not changed (a tool rewriting the same bytes) is hashed once but does not
    /// count as changed. A file that is gone counts as changed, and drops out of <see cref="Seen"/>.
    /// </summary>
    public bool HasChanged(string path)
    {
        AtomicFile.RequireFullPath(path);
        FileInfo info = new(path);
        if (!info.Exists)
        {
            return true;
        }
        long size = info.Length;
        long mtime = info.LastWriteTimeUtc.Ticks;
        Known.TryGetValue(path, out FileStamp? known);
        if (known is not null && known.Size == size && known.Mtime == mtime)
        {
            Seen[path] = known;
            return false;
        }
        string sha256 = hash(path);
        Seen[path] = new FileStamp(size, mtime, sha256);
        return known is null || !string.Equals(known.Sha256, sha256, StringComparison.Ordinal);
    }
}
