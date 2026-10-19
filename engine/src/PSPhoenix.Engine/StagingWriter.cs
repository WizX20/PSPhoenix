using System.Security.Cryptography;
using System.Text;

namespace PSPhoenix.Engine;

/// <summary>What staging one file did.</summary>
/// <param name="Scan">What the secret scan found.</param>
/// <param name="Sealed">It held a secret and was written encrypted, as <c>&lt;name&gt;.age</c>.</param>
public sealed record StagedFile(FileScan Scan, bool Sealed)
{
    /// <summary>It held a secret and there was no key to encrypt it to: nothing was written.</summary>
    public bool HeldBack => Scan.HasSecret && !Sealed;
}

/// <summary>
/// Encrypts staged secrets to the recipient in the config (docs/design.md -> Secrets). age output is
/// never the same twice, so a secret encrypted again every run would be a new file every run - and
/// a sync client would upload every secret every hour. The sealer keeps the last ciphertext of each
/// staged file in a cache folder in the state, and hands it out again as long as the plaintext and
/// the recipient are the same.
/// </summary>
public sealed class Sealer
{
    private readonly string cacheFolder;

    /// <summary>A sealer for <paramref name="recipient"/>, caching in <paramref name="cacheFolder"/> (machine-local, never backed up).</summary>
    public Sealer(string recipient, string cacheFolder)
    {
        if (!Age.IsRecipient(recipient))
        {
            throw new ArgumentException("not an age recipient (age1…)", nameof(recipient));
        }
        AtomicFile.RequireFullPath(cacheFolder);
        Recipient = recipient;
        this.cacheFolder = cacheFolder;
    }

    /// <summary>The recipient secrets are encrypted to.</summary>
    public string Recipient { get; }

    /// <summary>
    /// The age file for <paramref name="plaintext"/>, staged at <paramref name="path"/>: the cached one
    /// when neither the plaintext nor the recipient changed since, else a new one.
    /// </summary>
    internal byte[] Seal(string path, byte[] plaintext)
    {
        string id = Id(path);
        string cached = Path.Combine(cacheFolder, id + ".age");
        string stampFile = Path.Combine(cacheFolder, id + ".stamp");
        // The stamp names the plaintext, the recipient and the very ciphertext it vouches for: a
        // cached file that is not that one - a run that died between the two writes - is not used.
        string stamp = $"{Convert.ToHexString(SHA256.HashData(plaintext))} {Recipient}";
        if (File.Exists(stampFile) && File.Exists(cached))
        {
            string[] recorded = File.ReadAllText(stampFile).Split('\n');
            byte[] candidate = File.ReadAllBytes(cached);
            if (recorded.Length == 2 && recorded[0] == stamp && recorded[1] == Convert.ToHexString(SHA256.HashData(candidate)))
            {
                return candidate;
            }
        }
        byte[] encrypted = Age.Encrypt(plaintext, Recipient);
        AtomicFile.WriteAllBytes(cached, encrypted);
        AtomicFile.WriteAllText(stampFile, $"{stamp}\n{Convert.ToHexString(SHA256.HashData(encrypted))}");
        return encrypted;
    }

    /// <summary>
    /// Removes from the cache every ciphertext but those of <paramref name="kept"/> (full paths of
    /// staged files, as sealed): a secret no longer staged leaves no copy behind. Returns how many
    /// files went.
    /// </summary>
    public int Prune(IEnumerable<string> kept)
    {
        ArgumentNullException.ThrowIfNull(kept);
        if (!Directory.Exists(cacheFolder))
        {
            return 0;
        }
        HashSet<string> ids = new(kept.Select(Id), StringComparer.Ordinal);
        int removed = 0;
        foreach (string file in Directory.EnumerateFiles(cacheFolder).ToList())
        {
            // <id>.age and <id>.stamp; anything else - a temporary file of a run that died - goes too.
            string name = Path.GetFileName(file);
            if (!ids.Contains(name.Split('.')[0]))
            {
                File.Delete(file);
                removed++;
            }
        }
        return removed;
    }

    private static string Id(string path) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(path))));
}

/// <summary>
/// How a provider stages a file (docs/design.md -> Secrets): scanned first. A file without a secret
/// is written as it is. One with a secret is written encrypted as <c>&lt;name&gt;.age</c> when there
/// is a <see cref="Sealer"/>, and not at all without one. The scan and the write see the same bytes -
/// a file read once, never read again after the scan - and a plaintext secret never reaches the
/// disk: staging stays on disk between runs, so it must not land there even for a moment.
/// </summary>
public static class StagingWriter
{
    /// <summary>The extension of an encrypted file in staging and in the snapshot.</summary>
    public const string SealedExtension = ".age";

    /// <summary>Stages <paramref name="text"/> at <paramref name="path"/> as UTF-8, through a temporary file and a rename.</summary>
    public static StagedFile WriteText(string path, string text, Sealer? sealer = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        AtomicFile.RequireFullPath(path);
        return Stage(path, Encoding.UTF8.GetBytes(text), new FileScan(false, SecretScanner.Scan(text)), sealer);
    }

    /// <summary>
    /// Stages a copy of <paramref name="source"/> at <paramref name="path"/>. A binary file is copied
    /// unscanned (<see cref="FileScan.IsBinary"/>): its name decides whether it is secret, before it
    /// gets here.
    /// </summary>
    public static StagedFile CopyFile(string source, string path, Sealer? sealer = null) => CopyFile(source, path, sealer, secret: false);

    /// <summary>
    /// Stages a copy of <paramref name="source"/> at <paramref name="path"/>; with
    /// <paramref name="secret"/> - a file secret by its name, such as <c>.env</c> or a <c>.pfx</c> - it
    /// is only ever encrypted, whatever the scan finds, binary or not.
    /// </summary>
    public static StagedFile CopyFile(string source, string path, Sealer? sealer, bool secret) => CopyFile(source, path, sealer, secret, null);

    /// <summary>
    /// Stages a copy of <paramref name="source"/> at <paramref name="path"/>, as the review decided:
    /// with <paramref name="secret"/> only ever encrypted; findings whose
    /// <see cref="SecretFinding.Signature"/> is in <paramref name="accepted"/> - false positives the
    /// review overruled - do not make it secret. Any other finding still does.
    /// </summary>
    public static StagedFile CopyFile(string source, string path, Sealer? sealer, bool secret, IReadOnlyCollection<string>? accepted)
    {
        AtomicFile.RequireFullPath(source);
        AtomicFile.RequireFullPath(path);
        byte[] bytes = SecretScanner.ReadShared(source);
        string? text = SecretScanner.Decode(bytes);
        FileScan scan = text is null ? new FileScan(true, []) : new FileScan(false, SecretScanner.Scan(text));
        if (accepted is { Count: > 0 } && !secret)
        {
            HashSet<string> overruled = new(accepted, StringComparer.Ordinal);
            scan = scan with { Findings = [.. scan.Findings.Where(f => !overruled.Contains(f.Signature))] };
        }
        if (secret && !scan.HasSecret)
        {
            scan = scan with { Findings = [new SecretFinding(SecretKind.SecretFile, 1, 1)] };
        }
        return Stage(path, bytes, scan, sealer);
    }

    /// <summary>
    /// The last check on a file already in staging - one a provider wrote around the writer: with a
    /// secret in it, it is replaced by its encrypted copy, or removed when there is no sealer.
    /// </summary>
    public static StagedFile CheckStaged(string path, Sealer? sealer = null)
    {
        AtomicFile.RequireFullPath(path);
        byte[] bytes = SecretScanner.ReadShared(path);
        string? text = SecretScanner.Decode(bytes);
        FileScan scan = text is null ? new FileScan(true, []) : new FileScan(false, SecretScanner.Scan(text));
        if (!scan.HasSecret)
        {
            return new StagedFile(scan, false);
        }
        StagedFile staged = Stage(path, bytes, scan, sealer);
        File.Delete(path);
        return staged;
    }

    private static StagedFile Stage(string path, byte[] bytes, FileScan scan, Sealer? sealer)
    {
        if (!scan.HasSecret)
        {
            AtomicFile.WriteAllBytes(path, bytes);
            return new StagedFile(scan, false);
        }
        if (sealer is null)
        {
            return new StagedFile(scan, false);
        }
        AtomicFile.WriteAllBytes(path + SealedExtension, sealer.Seal(path, bytes));
        return new StagedFile(scan, true);
    }
}
