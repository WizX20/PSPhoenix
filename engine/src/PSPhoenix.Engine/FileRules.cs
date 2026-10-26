namespace PSPhoenix.Engine;

/// <summary>What happens to a gitignored file.</summary>
public enum FileDecision
{
    /// <summary>Nobody decided yet: not backed up, shown by the review.</summary>
    Pending,

    /// <summary>Backed up as it is - encrypted when its content holds a secret.</summary>
    Include,

    /// <summary>Backed up, and only ever encrypted.</summary>
    Secret,

    /// <summary>Not backed up: excluded by the review, or by a built-in filter.</summary>
    Exclude,
}

/// <summary>
/// The review's decisions for one repository (docs/design.md -> Config: <c>files.repos[identity]</c>),
/// and what they make of each gitignored file:
/// <list type="number">
/// <item>a <c>secret</c> pattern: backed up encrypted;</item>
/// <item>an <c>include</c> pattern: backed up - encrypted when its name or content says secret;</item>
/// <item>an <c>exclude</c> pattern: not backed up;</item>
/// <item>the same three for every repository (<c>files.secret</c>, <c>files.include</c>,
/// <c>files.exclude</c>): the repository's own decision on a file comes first;</item>
/// <item>a built-in filter (<see cref="CandidateFilter"/>): not backed up;</item>
/// <item>anything else is pending.</item>
/// </list>
/// So a folder excluded as a whole can still have one file in it included by name. Only a pattern
/// that names one file overrides a built-in filter: a folder or wildcard include does not pull in the
/// large, binary or generated files below it the review never showed.
/// </summary>
public sealed class FileRules
{
    private readonly PathPattern[] include;
    private readonly PathPattern[] secret;
    private readonly PathPattern[] exclude;
    private readonly FileRules? everyRepository;

    /// <summary>
    /// Rules from the config's pattern lists; throws on a pattern that is not one.
    /// <paramref name="everyRepository"/>: the decisions for every repository, which decide what the
    /// repository's own leave open.
    /// </summary>
    public FileRules(IEnumerable<string>? include = null, IEnumerable<string>? secret = null, IEnumerable<string>? exclude = null, FileRules? everyRepository = null)
    {
        this.include = Parse(include);
        this.secret = Parse(secret);
        this.exclude = Parse(exclude);
        this.everyRepository = everyRepository;
    }

    /// <summary>What happens to <paramref name="file"/>.</summary>
    public FileDecision Decide(IgnoredFile file)
    {
        ArgumentNullException.ThrowIfNull(file);
        bool filtered = file.Filter != CandidateFilter.None;
        FileDecision? decided = ByPattern(file, filtered) ?? everyRepository?.ByPattern(file, filtered);
        return decided ?? (filtered ? FileDecision.Exclude : FileDecision.Pending);
    }

    /// <summary>Whether an include or secret pattern matches <paramref name="path"/>.</summary>
    public bool Names(string path) => include.Concat(secret).Any(p => p.IsMatch(path)) || everyRepository?.Names(path) == true;

    /// <summary>Whether an include or secret pattern points into <paramref name="folder"/> by name: the walk enters it, denied or oversized.</summary>
    public bool PointsInto(string folder) => include.Concat(secret).Any(p => p.PointsInto(folder)) || everyRepository?.PointsInto(folder) == true;

    /// <summary>Whether an include or secret pattern can match below <paramref name="folder"/>: the walk must enter it, denied or not.</summary>
    public bool Reaches(string folder) => include.Concat(secret).Any(p => p.CouldMatchBelow(folder)) || everyRepository?.Reaches(folder) == true;

    /// <summary>
    /// Whether the walk can skip <paramref name="folder"/>: an exclude pattern covers everything in it,
    /// and no include or secret pattern reaches into it.
    /// </summary>
    public bool Prunes(string folder)
    {
        // A name no pattern of the user's spells out: only a pattern for the whole folder matches it.
        string probe = PathPattern.Normalize(folder).Trim('/') + "/";
        return Excludes(probe) && !Reaches(folder);
    }

    private bool Excludes(string probe) => exclude.Any(p => p.IsMatch(probe)) || everyRepository?.Excludes(probe) == true;

    /// <summary>What these patterns alone decide on <paramref name="file"/>: secret beats include beats exclude; nothing when none matches.</summary>
    private FileDecision? ByPattern(IgnoredFile file, bool filtered)
    {
        if (secret.Any(p => p.IsMatch(file.Path) && (p.Exact || !filtered)))
        {
            return FileDecision.Secret;
        }
        if (include.Any(p => p.IsMatch(file.Path) && (p.Exact || !filtered)))
        {
            return file.SecretName ? FileDecision.Secret : FileDecision.Include;
        }
        if (exclude.Any(p => p.IsMatch(file.Path)))
        {
            return FileDecision.Exclude;
        }
        return null;
    }

    private static PathPattern[] Parse(IEnumerable<string>? patterns) => [.. (patterns ?? []).Select(PathPattern.Parse)];
}
