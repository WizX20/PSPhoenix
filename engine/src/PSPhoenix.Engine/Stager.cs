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
/// One provider's staging for one run (docs/design.md -> Secrets: Staging): every file goes through
/// the <see cref="StagingWriter"/> rules, and the stager keeps a record of what each became. The
/// provider builds its manifest from that record, and the last check before publishing
/// (<see cref="CheckRest"/>) looks only at what reached the folder some other way - so a decision
/// the review made ("not a secret") is not undone by a second scan that does not know about it,
/// and no file is scanned twice.
/// </summary>
public sealed class Stager
{
    private readonly Sealer? sealer;
    private readonly Dictionary<string, StagedEntry> entries = new(StringComparer.Ordinal);

    /// <summary>A stager for the staging folder <paramref name="root"/>, encrypting with <paramref name="sealer"/> (none: secrets are held back).</summary>
    public Stager(string root, Sealer? sealer)
    {
        AtomicFile.RequireFullPath(root);
        Root = Path.GetFullPath(root);
        this.sealer = sealer;
    }

    /// <summary>The staging folder.</summary>
    public string Root { get; }

    /// <summary>What was staged, in order of the paths.</summary>
    public IReadOnlyList<StagedEntry> Entries => [.. entries.Values.OrderBy(e => e.Path, StringComparer.Ordinal)];

    /// <summary>The entry for <paramref name="path"/> (full, or relative to the root), or nothing.</summary>
    public StagedEntry? Find(string path) => entries.GetValueOrDefault(Relative(path));

    /// <summary>
    /// Stages <paramref name="text"/> at <paramref name="path"/> (a full path in the staging folder).
    /// With <paramref name="seal"/> false a secret is held back even when there is a key - for a
    /// file that must stay readable without one.
    /// </summary>
    public StagedEntry WriteText(string path, string text, bool seal = true)
    {
        string relative = Relative(path);
        StagedFile staged = StagingWriter.WriteText(path, text, seal ? sealer : null);
        return Record(relative, staged);
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
        if (relative.EndsWith(StagingWriter.SealedExtension, StringComparison.OrdinalIgnoreCase))
        {
            byte[] bytes = SecretScanner.ReadShared(source);
            if (Age.IsEncrypted(bytes))
            {
                AtomicFile.WriteAllBytes(path, bytes);
                return Remember(new StagedEntry(relative, relative, StagedAs.Plain, []));
            }
        }
        StagedFile staged = StagingWriter.CopyFile(source, path, sealer, secret, accepted);
        return Record(relative, staged);
    }

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
        HashSet<string> ours = new(entries.Values.Where(e => e.Stored is not null).Select(e => e.Stored!), StringComparer.Ordinal);
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
                found.Add(Record(relative, staged));
            }
        }
        return found;
    }

    private StagedEntry Record(string relative, StagedFile staged)
    {
        StagedAs how = staged.Sealed ? StagedAs.Sealed : staged.HeldBack ? StagedAs.HeldBack : StagedAs.Plain;
        string? stored = how switch
        {
            StagedAs.Sealed => relative + StagingWriter.SealedExtension,
            StagedAs.Plain => relative,
            _ => null,
        };
        return Remember(new StagedEntry(relative, stored, how, staged.Scan.Findings));
    }

    private StagedEntry Remember(StagedEntry entry)
    {
        entries[entry.Path] = entry;
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
