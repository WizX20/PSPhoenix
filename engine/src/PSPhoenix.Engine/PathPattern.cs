using System.Text;
using System.Text.RegularExpressions;

namespace PSPhoenix.Engine;

/// <summary>
/// A pattern for a path inside a repository, as the config's review decisions hold them
/// (docs/design.md -> Config): <c>config.local.env</c>, <c>**/appsettings*.local.json</c>,
/// <c>docker/</c>. Paths are relative to the repository, with <c>/</c>, and compare ignoring case -
/// the same decision on every platform.
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item><c>*</c> is any run of characters within a segment, <c>?</c> one character, <c>**</c> any
/// number of whole segments.</item>
/// <item>A pattern without a <c>/</c> (<c>*.local.json</c>, <c>.env</c>) matches a file or a folder
/// of that name at any depth, as in a <c>.gitignore</c>; one with a <c>/</c> - a leading one
/// included, <c>/notes.md</c> - matches from the repository's top.</item>
/// <item>A pattern ending in <c>/</c> names a folder: it matches everything below it.</item>
/// <item>A pattern that matches a folder matches every file below it.</item>
/// </list>
/// </remarks>
public sealed class PathPattern
{
    private readonly Regex regex;

    private PathPattern(string text, Regex regex)
    {
        Text = text;
        this.regex = regex;
    }

    /// <summary>The pattern as written.</summary>
    public string Text { get; }

    /// <summary>The pattern for <paramref name="text"/>; throws on an empty one, or one that leads out of the repository.</summary>
    public static PathPattern Parse(string text)
    {
        if (!TryParse(text, out PathPattern? pattern, out string? error))
        {
            throw new ArgumentException($"'{text}': {error}", nameof(text));
        }
        return pattern;
    }

    /// <summary>The pattern for <paramref name="text"/>, or why it is not one.</summary>
    public static bool TryParse(string? text, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out PathPattern? pattern, [System.Diagnostics.CodeAnalysis.NotNullWhen(false)] out string? error)
    {
        pattern = null;
        string body = Normalize(text ?? string.Empty);
        if (body.StartsWith("./", StringComparison.Ordinal))
        {
            body = body[2..];
        }
        bool rooted = body.StartsWith('/');
        body = body.TrimStart('/');
        if (body.Trim('/').Length == 0)
        {
            error = "an empty pattern";
            return false;
        }
        string[] segments = body.TrimEnd('/').Split('/');
        if (segments.Any(s => s is "." or ".." || s.Length == 0))
        {
            error = "a pattern is a path inside the repository: no empty, . or .. segments";
            return false;
        }
        bool folder = body.EndsWith('/');
        bool anchored = rooted || segments.Length > 1;
        StringBuilder regex = new("^");
        if (!anchored)
        {
            regex.Append("(?:.*/)?");
        }
        for (int i = 0; i < segments.Length; i++)
        {
            string segment = segments[i];
            bool last = i == segments.Length - 1;
            if (segment == "**")
            {
                // Any number of whole segments, none included.
                regex.Append(last ? ".*" : "(?:[^/]+/)*");
                continue;
            }
            foreach (char c in segment)
            {
                regex.Append(c switch
                {
                    '*' => "[^/]*",
                    '?' => "[^/]",
                    _ => Regex.Escape(c.ToString()),
                });
            }
            if (!last)
            {
                regex.Append('/');
            }
        }
        // A folder's files match through it; a file pattern also names a folder of that name.
        regex.Append(folder ? "/.*$" : "(?:/.*)?$");
        pattern = new PathPattern(text!, new Regex(regex.ToString(), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)));
        error = null;
        return true;
    }

    /// <summary>Whether <paramref name="path"/>, relative to the repository, matches.</summary>
    public bool IsMatch(string path) => regex.IsMatch(Normalize(path).TrimStart('/'));

    /// <summary>A path with <c>/</c> as its separator.</summary>
    internal static string Normalize(string path) => path.Replace('\\', '/');

    /// <inheritdoc/>
    public override string ToString() => Text;
}
