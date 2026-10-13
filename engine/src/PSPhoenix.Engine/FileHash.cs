using System.Security.Cryptography;
using System.Text;

namespace PSPhoenix.Engine;

/// <summary>SHA-256, as upper-case hex - the form the state and the snapshot record.</summary>
public static class FileHash
{
    /// <summary>The SHA-256 of a file's content.</summary>
    public static string Sha256(string path)
    {
        AtomicFile.RequireFullPath(path);
        // Shared with writers and deleters: hashing a file another program has open (an editor,
        // Claude Code writing its memory) must not fail, nor block that program.
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, bufferSize: 1 << 16, FileOptions.SequentialScan);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    /// <summary>The SHA-256 of a text, as UTF-8.</summary>
    public static string Sha256Text(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }
}
