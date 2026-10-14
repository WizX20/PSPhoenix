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
/// <item>an <c>exclude</c> pattern, of the repository or of every repository (<c>files.exclude</c>):
/// not backed up;</item>
/// <item>a built-in filter (<see cref="CandidateFilter"/>): not backed up;</item>
/// <item>anything else is pending.</item>
/// </list>
/// So a folder excluded as a whole can still have one file in it included by name.
/// </summary>
public sealed class FileRules
{
    private readonly PathPattern[] include;
    private readonly PathPattern[] secret;
    private readonly PathPattern[] exclude;

    /// <summary>Rules from the config's pattern lists; throws on a pattern that is not one.</summary>
    public FileRules(IEnumerable<string>? include = null, IEnumerable<string>? secret = null, IEnumerable<string>? exclude = null)
    {
        this.include = Parse(include);
        this.secret = Parse(secret);
        this.exclude = Parse(exclude);
    }

    /// <summary>What happens to <paramref name="file"/>.</summary>
    public FileDecision Decide(IgnoredFile file)
    {
        ArgumentNullException.ThrowIfNull(file);
        if (secret.Any(p => p.IsMatch(file.Path)))
        {
            return FileDecision.Secret;
        }
        if (include.Any(p => p.IsMatch(file.Path)))
        {
            return file.SecretName ? FileDecision.Secret : FileDecision.Include;
        }
        if (exclude.Any(p => p.IsMatch(file.Path)) || file.Filter != CandidateFilter.None)
        {
            return FileDecision.Exclude;
        }
        return FileDecision.Pending;
    }

    private static PathPattern[] Parse(IEnumerable<string>? patterns) => [.. (patterns ?? []).Select(PathPattern.Parse)];
}
