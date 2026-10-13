using System.Text;

namespace PSPhoenix.Engine;

/// <summary>
/// Writes files so that a reader - the scheduled run, a sync client - never sees half a file, or no
/// file at all (docs/design.md -> Targets): into a temporary name next to the file, then one rename
/// over it.
/// </summary>
public static class AtomicFile
{
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>How often <see cref="MoveIntoPlace"/> tries, and how long it waits in between.</summary>
    internal const int Attempts = 20;

    internal static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(50);

    /// <summary>Writes <paramref name="value"/> as UTF-8 without a BOM.</summary>
    public static void WriteAllText(string path, string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        string temporary = TemporaryPath(path);
        try
        {
            File.WriteAllText(temporary, value, Utf8);
            MoveIntoPlace(temporary, path);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    /// <summary>Copies <paramref name="source"/> to <paramref name="path"/>.</summary>
    public static void Copy(string source, string path)
    {
        RequireFullPath(source);
        string temporary = TemporaryPath(path);
        try
        {
            File.Copy(source, temporary, overwrite: true);
            MoveIntoPlace(temporary, path);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    /// <summary>
    /// One rename of <paramref name="temporary"/> over <paramref name="path"/>. A move with overwrite
    /// replaces the file in place (MoveFileEx on Windows, rename(2) elsewhere); deleting it first
    /// would leave a moment with no file - a reader then takes "no config" for "not set up yet".
    /// </summary>
    public static void MoveIntoPlace(string temporary, string path)
    {
        RequireFullPath(temporary);
        RequireFullPath(path);
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                File.Move(temporary, path, overwrite: true);
                return;
            }
            // On Windows a reader that holds the file open (a sync client, a virus scanner) blocks
            // the replace for a moment. Retry for about a second.
            catch (Exception e) when (e is IOException or UnauthorizedAccessException && attempt < Attempts)
            {
                Thread.Sleep(RetryDelay);
            }
        }
    }

    /// <summary>
    /// A uniquely named temporary file next to <paramref name="path"/>, its folder created:
    /// <c>.&lt;name&gt;.&lt;8 hex digits&gt;.tmp</c>. Two writers never share one, and a run that
    /// died half-way leaves a name the next one recognises.
    /// </summary>
    public static string TemporaryPath(string path)
    {
        RequireFullPath(path);
        string folder = Path.GetDirectoryName(path) ?? throw new ArgumentException($"{path} is a root, not a file", nameof(path));
        Directory.CreateDirectory(folder);
        return Path.Combine(folder, $".{Path.GetFileName(path)}.{Guid.NewGuid().ToString("N")[..8]}.tmp");
    }

    /// <summary>
    /// A relative path would be resolved against the process's folder, which in PowerShell is not
    /// the current location: refuse it rather than write somewhere unexpected.
    /// </summary>
    internal static void RequireFullPath(string path, [System.Runtime.CompilerServices.CallerArgumentExpression(nameof(path))] string? name = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(path, name);
        if (!Path.IsPathFullyQualified(path))
        {
            throw new ArgumentException($"{path} is not a full path", name);
        }
    }
}
