namespace PSPhoenix.Engine;

/// <summary>What one <see cref="FolderPublisher.Publish(string, string, IDictionary{string, string}?)"/> did.</summary>
/// <param name="Written">Files copied in: new, or changed.</param>
/// <param name="Unchanged">Files left alone: the destination held them already.</param>
/// <param name="Removed">Files removed: no longer in the source.</param>
/// <param name="Files">Files in the source.</param>
public sealed record PublishResult(int Written, int Unchanged, int Removed, int Files);

/// <summary>A file that could not be published; the message names it, relative to the folder.</summary>
public sealed class PublishException : IOException
{
    /// <summary>The file, relative to the folder published.</summary>
    public string RelativePath { get; }

    internal PublishException(string relativePath, Exception inner)
        : base($"{relativePath}: {inner.Message}", inner)
    {
        RelativePath = relativePath;
    }
}

/// <summary>
/// Publishing a staged folder into the snapshot (docs/design.md -> Snapshot layout): the
/// destination ends up holding exactly the files of the source. A new or changed file is copied in
/// through a temporary name and a rename, an identical one is left alone, any other file is
/// removed - a stale temporary one included - and so are the folders left empty. A run with
/// nothing changed writes nothing, so a sync client uploads nothing.
/// </summary>
public static class FolderPublisher
{
    /// <summary>
    /// Makes <paramref name="destination"/> hold exactly the files of <paramref name="source"/>.
    /// </summary>
    /// <remarks>
    /// The removal comes first, so a file that became a folder (or the other way round) is out of
    /// the way before the copy needs its place. Which files to keep is decided ignoring case, on
    /// every platform: a destination on a case-insensitive drive (Windows, a NAS, a USB disk) holds
    /// one file under either spelling, and removing "the other one" would remove the file just
    /// kept. A file staged under another spelling than the published one is removed and copied
    /// again, so a rename that only changes case reaches the snapshot too.
    /// </remarks>
    /// <param name="source">The staged folder; a missing one counts as empty.</param>
    /// <param name="destination">The provider's folder in the snapshot.</param>
    /// <param name="published">
    /// Relative path -> SHA-256 as last published, from the state; it spares reading the
    /// destination back - reading a file in a OneDrive folder can mean downloading it first. A
    /// staged file whose hash matches, with the published file still there at its length, is
    /// unchanged. Updated to what the destination holds afterwards; a file that failed drops out.
    /// </param>
    /// <exception cref="PublishException">A file could not be read, written or removed.</exception>
    public static PublishResult Publish(string source, string destination, IDictionary<string, string>? published)
        => Publish(source, destination, published, FileHash.Sha256);

    /// <summary>
    /// True when <paramref name="path"/> exists with the content of <paramref name="source"/>: the
    /// length first, the hashes only then. <paramref name="sourceHash"/> is the source's hash when
    /// the caller has it already.
    /// </summary>
    public static bool SameContent(string source, string path, string? sourceHash = null)
        => SameContent(source, path, sourceHash, FileHash.Sha256);

    /// <summary>Publish with the hash function given: the tests see which files it reads.</summary>
    internal static PublishResult Publish(string source, string destination, IDictionary<string, string>? published, Func<string, string> hash)
    {
        AtomicFile.RequireFullPath(source);
        AtomicFile.RequireFullPath(destination);
        List<string> staged = Directory.Exists(source)
            ? Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories).Select(file => Path.GetRelativePath(source, file)).ToList()
            : [];
        staged.Sort(StringComparer.Ordinal);
        HashSet<string> wanted = new(staged, StringComparer.OrdinalIgnoreCase);
        HashSet<string> exact = new(staged, StringComparer.Ordinal);
        int written = 0, unchanged = 0, removed = 0;

        if (Directory.Exists(destination))
        {
            foreach (string file in Directory.EnumerateFiles(destination, "*", SearchOption.AllDirectories).ToList())
            {
                string relative = Path.GetRelativePath(destination, file);
                if (exact.Contains(relative))
                {
                    continue;
                }
                Named(relative, () => File.Delete(file));
                if (!wanted.Contains(relative))
                {
                    removed++;
                }
            }
            // Deepest first: a folder whose only content was an empty folder goes too.
            foreach (string folder in Directory.EnumerateDirectories(destination, "*", SearchOption.AllDirectories).OrderByDescending(f => f.Length).ToList())
            {
                if (!Directory.EnumerateFileSystemEntries(folder).Any())
                {
                    Named(Path.GetRelativePath(destination, folder), () => Directory.Delete(folder));
                }
            }
        }

        foreach (string relative in staged)
        {
            string file = Path.Combine(source, relative);
            string target = Path.Combine(destination, relative);
            try
            {
                string sourceHash = hash(file);
                bool known = published is not null
                    && published.TryGetValue(relative, out string? last)
                    && string.Equals(last, sourceHash, StringComparison.Ordinal)
                    && File.Exists(target)
                    && new FileInfo(target).Length == new FileInfo(file).Length;
                if (known || SameContent(file, target, sourceHash, hash))
                {
                    unchanged++;
                }
                else
                {
                    AtomicFile.Copy(file, target);
                    written++;
                }
                if (published is not null)
                {
                    // Removed first: a dictionary that ignores case keeps the old spelling otherwise.
                    published.Remove(relative);
                    published[relative] = sourceHash;
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                published?.Remove(relative);
                throw new PublishException(relative, e);
            }
        }

        if (published is not null)
        {
            foreach (string key in published.Keys.Where(key => !exact.Contains(key)).ToList())
            {
                published.Remove(key);
            }
        }
        return new PublishResult(written, unchanged, removed, staged.Count);
    }

    internal static bool SameContent(string source, string path, string? sourceHash, Func<string, string> hash)
    {
        if (!File.Exists(path) || new FileInfo(source).Length != new FileInfo(path).Length)
        {
            return false;
        }
        return string.Equals(sourceHash ?? hash(source), hash(path), StringComparison.Ordinal);
    }

    /// <summary>A removal that fails names the file.</summary>
    private static void Named(string relative, Action action)
    {
        try
        {
            action();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new PublishException(relative, e);
        }
    }
}
