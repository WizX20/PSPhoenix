namespace PSPhoenix.Engine;

/// <summary>How a file went into staging.</summary>
public enum StagedAs
{
    /// <summary>As it is: no secret in it, or only findings the review called no secret.</summary>
    Plain,

    /// <summary>Encrypted, as <c>&lt;name&gt;.age</c>.</summary>
    Sealed,

    /// <summary>Not written: it holds a secret and there is no key (or the caller wanted it plain only).</summary>
    HeldBack,
}

/// <summary>One file a <see cref="Stager"/> staged.</summary>
/// <param name="Path">Where it was asked to go, relative to the staging folder, with <c>/</c>.</param>
/// <param name="Stored">The file that holds it, relative, with <c>/</c>: <see cref="Path"/>, or <see cref="Path"/><c>.age</c>; nothing when held back.</param>
/// <param name="As">Plain, sealed or held back.</param>
/// <param name="Findings">The secrets that made it sealed or held back - never their values.</param>
public sealed record StagedEntry(string Path, string? Stored, StagedAs As, IReadOnlyList<SecretFinding> Findings);

/// <summary>
/// What a run staged at one path, kept in the state for the next run: the source as it was (size and
/// mtime, or the text's hash), how it was staged, and the staged file as it was left (size, mtime,
/// SHA-256). An unchanged source with its staged file untouched is not read, scanned or hashed again.
/// </summary>
/// <param name="Source">The file copied (full path); nothing for a text.</param>
/// <param name="SourceSize">Its size.</param>
/// <param name="SourceMtime">Its last write time, UTC ticks.</param>
/// <param name="Options">How it was staged: the kind, the text's hash, secret, accepted findings, the recipient.</param>
/// <param name="Stored">The staged file, relative with <c>/</c>; nothing when held back.</param>
/// <param name="As">Plain, sealed or held back.</param>
/// <param name="Findings">The secrets that made it sealed or held back.</param>
/// <param name="StagedSize">The staged file's size.</param>
/// <param name="StagedMtime">The staged file's last write time, UTC ticks.</param>
/// <param name="Sha256">The staged file's SHA-256, for publishing.</param>
public sealed record StagedRecord(
    string? Source,
    long SourceSize,
    long SourceMtime,
    string Options,
    string? Stored,
    StagedAs As,
    IReadOnlyList<SecretFinding> Findings,
    long StagedSize,
    long StagedMtime,
    string? Sha256);

/// <summary>
/// One provider's staging for one run (docs/design.md -> Secrets: Staging): every file goes through
/// the <see cref="StagingWriter"/> rules, and the stager keeps a record of what each became. The
/// provider builds its manifest from that record, and the last check before publishing
/// (<see cref="CheckRest"/>) looks only at what reached the folder some other way - so a decision
/// the review made ("not a secret") is not undone by a second scan that does not know about it,
/// and no file is scanned twice.
/// </summary>
/// <remarks>
/// The staging folder stays between runs (docs/design.md -> Change detection). Given the records of
/// the last run, a file whose source and options are unchanged and whose staged copy is untouched
/// is left as it is - not read, scanned, encrypted or hashed - and <see cref="Prune"/> removes what
/// this run no longer staged.
/// </remarks>
public sealed class Stager
{
    private readonly Sealer? sealer;
    private readonly IReadOnlyDictionary<string, StagedRecord> previous;
    private readonly Dictionary<string, StagedEntry> entries = new(StringComparer.Ordinal);
    private readonly Dictionary<string, StagedRecord> records = new(StringComparer.Ordinal);
    private Dictionary<string, StagedRecord>? byStored;
    private readonly HashSet<string> reused = new(StringComparer.Ordinal);

    /// <summary>A stager for the staging folder <paramref name="root"/>, encrypting with <paramref name="sealer"/> (none: secrets are held back).</summary>
    public Stager(string root, Sealer? sealer)
        : this(root, sealer, null)
    {
    }

    /// <summary>A stager that reuses what the last run staged, as <paramref name="previous"/> records it.</summary>
    public Stager(string root, Sealer? sealer, IReadOnlyDictionary<string, StagedRecord>? previous)
    {
        AtomicFile.RequireFullPath(root);
        Root = Path.GetFullPath(root);
        this.sealer = sealer;
        this.previous = previous ?? new Dictionary<string, StagedRecord>();
    }

    /// <summary>The staging folder.</summary>
    public string Root { get; }

    /// <summary>What was staged, in order of the paths.</summary>
    public IReadOnlyList<StagedEntry> Entries => [.. entries.Values.OrderBy(e => e.Path, StringComparer.Ordinal)];

    /// <summary>What this run staged, for the next run.</summary>
    public IReadOnlyDictionary<string, StagedRecord> Records => records;

    /// <summary>How many files were left as the last run staged them.</summary>
    public int Reused { get; private set; }

    /// <summary>Whether the entry at <paramref name="relative"/> was left as the last run staged it.</summary>
    public bool WasReused(string relative) => reused.Contains(relative.Replace('\\', '/'));

    /// <summary>The entry for <paramref name="path"/> (full, or relative to the root), or nothing.</summary>
    public StagedEntry? Find(string path) => entries.GetValueOrDefault(Relative(path));

    /// <summary>
    /// Stages <paramref name="text"/> at <paramref name="path"/> (a full path in the staging folder).
    /// With <paramref name="seal"/> false a secret is held back even when there is a key - for a
    /// file that must stay readable without one.
    /// </summary>
    public StagedEntry WriteText(string path, string text, bool seal = true)
    {
        ArgumentNullException.ThrowIfNull(text);
        string relative = Relative(path);
        string options = $"text|{FileHash.Sha256Text(text)}|{seal}|{sealer?.Recipient}";
        if (TryReuse(relative, null, 0, 0, options) is { } reused)
        {
            return reused;
        }
        StagedFile staged = StagingWriter.WriteText(path, text, seal ? sealer : null);
        return Record(relative, staged, null, 0, 0, options);
    }

    /// <summary>
    /// Stages a copy of <paramref name="source"/> at <paramref name="path"/> (a full path in the
    /// staging folder): <paramref name="secret"/> only ever encrypted; findings in
    /// <paramref name="accepted"/> the review called no secret. A file that is already an age file
    /// (its header parses), staged under a <c>.age</c> name, is copied as it is.
    /// </summary>
    public StagedEntry CopyFile(string source, string path, bool secret = false, IReadOnlyCollection<string>? accepted = null)
    {
        string relative = Relative(path);
        AtomicFile.RequireFullPath(source);
        string full = Path.GetFullPath(source);
        FileInfo info = new(full);
        if (!info.Exists)
        {
            throw new FileNotFoundException($"{full} not found", full);
        }
        long size = info.Length;
        long mtime = info.LastWriteTimeUtc.Ticks;
        string options = $"copy|{secret}|{string.Join(',', (accepted ?? []).Order(StringComparer.Ordinal))}|{sealer?.Recipient}";
        if (TryReuse(relative, full, size, mtime, options) is { } reused)
        {
            return reused;
        }
        if (relative.EndsWith(StagingWriter.SealedExtension, StringComparison.OrdinalIgnoreCase))
        {
            byte[] bytes = SecretScanner.ReadShared(full);
            if (Age.IsEncrypted(bytes))
            {
                AtomicFile.WriteAllBytes(path, bytes);
                return Remember(new StagedEntry(relative, relative, StagedAs.Plain, []), full, size, mtime, options);
            }
        }
        StagedFile staged = StagingWriter.CopyFile(full, path, sealer, secret, accepted);
        return Record(relative, staged, full, size, mtime, options);
    }

    /// <summary>
    /// Removes what the last run staged and this one did not: every file in the staging folder this
    /// stager did not stage, last written before <paramref name="runStart"/> - a file a provider
    /// wrote around the stager in this run stays, for <see cref="CheckRest"/>. Returns how many.
    /// </summary>
    public int Prune(DateTime runStart)
    {
        if (!Directory.Exists(Root))
        {
            return 0;
        }
        HashSet<string> ours = Ours();
        int removed = 0;
        foreach (string file in Directory.EnumerateFiles(Root, "*", SearchOption.AllDirectories).ToList())
        {
            if (!ours.Contains(Relative(file)) && File.GetLastWriteTimeUtc(file) < runStart.ToUniversalTime())
            {
                File.Delete(file);
                removed++;
            }
        }
        foreach (string folder in Directory.EnumerateDirectories(Root, "*", SearchOption.AllDirectories).OrderByDescending(f => f.Length).ToList())
        {
            if (!Directory.EnumerateFileSystemEntries(folder).Any())
            {
                Directory.Delete(folder);
            }
        }
        return removed;
    }

    /// <summary>
    /// Removes from the sealer's cache the ciphertexts of files this run did not stage encrypted -
    /// after <see cref="CheckRest"/>, which may seal more. Returns how many cache files went.
    /// </summary>
    public int PruneSealed() =>
        sealer?.Prune(entries.Values.Where(e => e.As == StagedAs.Sealed).Select(e => Path.Combine(Root, e.Path))) ?? 0;

    /// <summary>
    /// The last check before publishing: every file in the staging folder this stager did not write
    /// is scanned, and one with a secret encrypted - or removed, without a key. Returns what it did
    /// to those with a secret.
    /// </summary>
    public IReadOnlyList<StagedEntry> CheckRest()
    {
        if (!Directory.Exists(Root))
        {
            return [];
        }
        HashSet<string> ours = Ours();
        List<StagedEntry> found = [];
        foreach (string file in Directory.EnumerateFiles(Root, "*", SearchOption.AllDirectories).ToList())
        {
            string relative = Relative(file);
            if (ours.Contains(relative))
            {
                continue;
            }
            StagedFile staged = StagingWriter.CheckStaged(file, sealer);
            if (staged.Scan.HasSecret)
            {
                found.Add(Remember(Entry(relative, staged), null, 0, 0, null));
            }
        }
        return found;
    }

    /// <summary>
    /// The SHA-256 of a staged file the stager wrote or kept, by its path relative to the staging
    /// folder (either separator) - publishing need not read it again. Nothing when it does not know.
    /// </summary>
    public string? KnownHash(string relative)
    {
        string key = relative.Replace('\\', '/');
        byStored ??= records.Values.Where(r => r.Stored is not null).ToDictionary(r => r.Stored!, StringComparer.Ordinal);
        if (!byStored.TryGetValue(key, out StagedRecord? record) || record.Sha256 is null)
        {
            return null;
        }
        // Only while the file is as it was left: a change after the stager wrote it is read.
        FileInfo info = new(Path.Combine(Root, key));
        return info.Exists && info.Length == record.StagedSize && info.LastWriteTimeUtc.Ticks == record.StagedMtime ? record.Sha256 : null;
    }

    private HashSet<string> Ours() => new(entries.Values.Where(e => e.Stored is not null).Select(e => e.Stored!), StringComparer.Ordinal);

    // The last run's staging of this path, when its source, its options and its staged file are all
    // as they were.
    private StagedEntry? TryReuse(string relative, string? source, long size, long mtime, string options)
    {
        if (!previous.TryGetValue(relative, out StagedRecord? last)
            || !string.Equals(last.Source, source, PathComparison.Comparison)
            || last.SourceSize != size
            || last.SourceMtime != mtime
            || !string.Equals(last.Options, options, StringComparison.Ordinal))
        {
            return null;
        }
        if (last.Stored is not null)
        {
            FileInfo staged = new(Path.Combine(Root, last.Stored));
            if (!staged.Exists || staged.Length != last.StagedSize || staged.LastWriteTimeUtc.Ticks != last.StagedMtime)
            {
                return null;
            }
            // A plain file whose sealed sibling (or the other way round) is also there is stale.
            string other = last.As == StagedAs.Sealed ? relative : relative + StagingWriter.SealedExtension;
            if (File.Exists(Path.Combine(Root, other)))
            {
                return null;
            }
        }
        Reused++;
        reused.Add(relative);
        StagedEntry entry = new(relative, last.Stored, last.As, last.Findings);
        entries[relative] = entry;
        records[relative] = last;
        byStored = null;
        return entry;
    }

    private StagedEntry Record(string relative, StagedFile staged, string? source, long size, long mtime, string options)
    {
        // What was there under the other name (plain before, sealed now, or the reverse) goes.
        foreach (string stale in new[] { relative, relative + StagingWriter.SealedExtension })
        {
            string file = Path.Combine(Root, stale);
            bool keep = staged.Sealed ? stale != relative : !staged.HeldBack && stale == relative;
            if (!keep)
            {
                if (File.Exists(file))
                {
                    File.Delete(file);
                }
            }
        }
        return Remember(Entry(relative, staged), source, size, mtime, options);
    }

    private static StagedEntry Entry(string relative, StagedFile staged)
    {
        StagedAs how = staged.Sealed ? StagedAs.Sealed : staged.HeldBack ? StagedAs.HeldBack : StagedAs.Plain;
        string? stored = how switch
        {
            StagedAs.Sealed => relative + StagingWriter.SealedExtension,
            StagedAs.Plain => relative,
            _ => null,
        };
        return new StagedEntry(relative, stored, how, staged.Scan.Findings);
    }

    private StagedEntry Remember(StagedEntry entry, string? source, long size, long mtime, string? options)
    {
        entries[entry.Path] = entry;
        byStored = null;
        if (options is null)
        {
            records.Remove(entry.Path);
            return entry;
        }
        long stagedSize = 0, stagedMtime = 0;
        string? sha256 = null;
        if (entry.Stored is not null)
        {
            FileInfo info = new(Path.Combine(Root, entry.Stored));
            stagedSize = info.Length;
            stagedMtime = info.LastWriteTimeUtc.Ticks;
            sha256 = FileHash.Sha256(info.FullName);
        }
        records[entry.Path] = new StagedRecord(source, size, mtime, options, entry.Stored, entry.As, entry.Findings, stagedSize, stagedMtime, sha256);
        return entry;
    }

    // A path in the staging folder, relative and with /. Anything outside it is refused: a provider
    // writes nowhere else.
    private string Relative(string path)
    {
        string full = Path.IsPathFullyQualified(path) ? Path.GetFullPath(path) : Path.GetFullPath(Path.Combine(Root, path));
        string relative = Path.GetRelativePath(Root, full);
        if (relative == "." || relative == ".." || relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) || Path.IsPathRooted(relative))
        {
            throw new ArgumentException($"{path} is not a file in the staging folder {Root}", nameof(path));
        }
        return relative.Replace('\\', '/');
    }
}
