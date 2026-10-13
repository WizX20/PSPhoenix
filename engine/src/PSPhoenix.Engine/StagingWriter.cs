namespace PSPhoenix.Engine;

/// <summary>
/// How a provider stages a file (docs/design.md -> Secrets): scanned first, written only when it
/// holds no secret. The scan and the write see the same bytes - a file read once, never read again
/// after the scan - and a text with a secret never reaches the disk: staging stays on disk between
/// runs, so a plaintext secret must not land there even for a moment.
/// </summary>
public static class StagingWriter
{
    /// <summary>
    /// Writes <paramref name="text"/> to <paramref name="path"/> as UTF-8, through a temporary file
    /// and a rename - unless it holds a secret: then nothing is written. Returns what the scan found.
    /// </summary>
    public static FileScan WriteText(string path, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        AtomicFile.RequireFullPath(path);
        FileScan scan = new(false, SecretScanner.Scan(text));
        if (!scan.HasSecret)
        {
            AtomicFile.WriteAllText(path, text);
        }
        return scan;
    }

    /// <summary>
    /// Copies <paramref name="source"/> to <paramref name="path"/> - unless it is a text that holds a
    /// secret: then nothing is written. A binary file is copied unscanned (<see cref="FileScan.IsBinary"/>):
    /// its name decides whether it is secret, before it gets here. Returns what the scan found.
    /// </summary>
    public static FileScan CopyFile(string source, string path)
    {
        AtomicFile.RequireFullPath(source);
        AtomicFile.RequireFullPath(path);
        byte[] bytes = SecretScanner.ReadShared(source);
        string? text = SecretScanner.Decode(bytes);
        FileScan scan = text is null ? new FileScan(true, []) : new FileScan(false, SecretScanner.Scan(text));
        if (!scan.HasSecret)
        {
            AtomicFile.WriteAllBytes(path, bytes);
        }
        return scan;
    }
}
