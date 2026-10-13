namespace PSPhoenix.Engine;

/// <summary>
/// Paths compare as the platform compares them: ignoring case on Windows, exactly elsewhere - the
/// module's Get-PhxPathComparison.
/// </summary>
internal static class PathComparison
{
    public static StringComparison Comparison { get; } =
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public static StringComparer Comparer { get; } = StringComparer.FromComparison(Comparison);

    /// <summary>A dictionary keyed by path.</summary>
    public static Dictionary<string, T> NewDictionary<T>() => new(Comparer);
}
