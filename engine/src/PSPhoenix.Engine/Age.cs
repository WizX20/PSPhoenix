using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using PSPhoenix.Engine.Crypto;

namespace PSPhoenix.Engine;

/// <summary>Why an age file could not be decrypted, in the categories of the age test vectors.</summary>
public enum AgeFailure
{
    /// <summary>The header is not a valid age v1 header.</summary>
    Header,

    /// <summary>No stanza in the header opens with the identity or passphrase given.</summary>
    NoMatch,

    /// <summary>A stanza opened, but the header's MAC does not match: the header was changed.</summary>
    Hmac,

    /// <summary>The encrypted payload does not decrypt to its end.</summary>
    Payload,
}

/// <summary>An age file that could not be decrypted, and why.</summary>
public sealed class AgeException : Exception
{
    internal AgeException(AgeFailure failure, string message, byte[]? released = null)
        : base(message)
    {
        Failure = failure;
        Released = released ?? [];
    }

    /// <summary>The category of the failure.</summary>
    public AgeFailure Failure { get; }

    /// <summary>What a streaming reader would have handed out before the payload failed (the test vectors check it).</summary>
    internal byte[] Released { get; }
}

/// <summary>An age key pair: the identity (secret) and its recipient (public).</summary>
/// <param name="Identity"><c>AGE-SECRET-KEY-1…</c>: decrypts. Never stored in plain text.</param>
/// <param name="Recipient"><c>age1…</c>: encrypts. Goes into the config.</param>
public sealed record AgeKey(string Identity, string Recipient)
{
    /// <summary>The recipient only: a key pair is printed or logged without its secret half.</summary>
    public override string ToString() => Recipient;
}

/// <summary>
/// age (age-encryption.org/v1), built in, so a user installs nothing: X25519 recipients and
/// scrypt passphrases, the header and its MAC, the STREAM payload. A file written here opens with
/// the age tool, and one the age tool wrote opens here - the official test vectors (C2SP CCTV) and,
/// in CI, the age tool itself check both directions. Not built: the ASCII armor, plugins and the
/// post-quantum hybrid recipients - PSPhoenix writes none of them.
/// </summary>
public static class Age
{
    /// <summary>The scrypt work factor a passphrase is encrypted with: 2^18, as the age tool uses.</summary>
    public const int DefaultWorkFactor = 18;

    /// <summary>The highest scrypt work factor accepted when decrypting, as the age tool: 2^22.</summary>
    public const int MaxWorkFactor = 22;

    private const string Version = "age-encryption.org/v1";
    private const string X25519Label = "age-encryption.org/v1/X25519";
    private const string ScryptLabel = "age-encryption.org/v1/scrypt";
    private const string IdentityPrefix = "age-secret-key-";
    private const string RecipientPrefix = "age";
    private const int FileKeySize = 16;
    private const int TagSize = 16;
    private const int NonceSize = 16;
    private const int ChunkSize = 64 * 1024;

    /// <summary>A new key pair.</summary>
    public static AgeKey NewKey()
    {
        byte[] secret = RandomNumberGenerator.GetBytes(X25519.Size);
        try
        {
            return new AgeKey(Bech32.Encode(IdentityPrefix, secret).ToUpperInvariant(), Bech32.Encode(RecipientPrefix, X25519.PublicKey(secret)));
        }
        finally
        {
            Array.Clear(secret);
        }
    }

    /// <summary>The recipient of an identity.</summary>
    public static string RecipientOf(string identity)
    {
        byte[] secret = ParseIdentity(identity);
        try
        {
            return Bech32.Encode(RecipientPrefix, X25519.PublicKey(secret));
        }
        finally
        {
            Array.Clear(secret);
        }
    }

    /// <summary>
    /// Whether <paramref name="text"/> is an X25519 recipient: <c>age1…</c>, lower case, 32 bytes, and
    /// not a low-order point - encrypting to one would make the file key public.
    /// </summary>
    public static bool IsRecipient(string text) => ParseRecipient(text) is not null;

    /// <summary>Whether <paramref name="text"/> is an X25519 identity: <c>AGE-SECRET-KEY-1…</c>, upper case.</summary>
    public static bool IsIdentity(string text) => TryParseKey(text, IdentityPrefix, KeyCase.Upper) is not null;

    /// <summary>Whether <paramref name="file"/> is an age file: a header that parses, and a payload's nonce after it.</summary>
    public static bool IsEncrypted(byte[] file)
    {
        ArgumentNullException.ThrowIfNull(file);
        if (!file.AsSpan().StartsWith("age-encryption.org/v1\n"u8))
        {
            return false;
        }
        try
        {
            return file.Length - ParseHeader(file).PayloadStart >= NonceSize + TagSize;
        }
        catch (AgeException)
        {
            return false;
        }
    }

    /// <summary>Encrypts <paramref name="plaintext"/> to <paramref name="recipient"/>.</summary>
    public static byte[] Encrypt(byte[] plaintext, string recipient)
    {
        ArgumentNullException.ThrowIfNull(plaintext);
        byte[] publicKey = ParseRecipient(recipient) ?? throw new ArgumentException("not an age recipient (age1…)", nameof(recipient));
        byte[] fileKey = RandomNumberGenerator.GetBytes(FileKeySize);
        byte[] ephemeral = RandomNumberGenerator.GetBytes(X25519.Size);
        byte[] shared = [];
        byte[] wrapKey = [];
        try
        {
            byte[] share = X25519.PublicKey(ephemeral);
            shared = X25519.ScalarMult(ephemeral, publicKey);
            if (IsZero(shared))
            {
                throw new ArgumentException("the recipient is a low-order point", nameof(recipient));
            }
            wrapKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, [.. share, .. publicKey], Encoding.ASCII.GetBytes(X25519Label));
            Stanza stanza = new(["X25519", Base64(share)], Seal(wrapKey, fileKey));
            return Write(fileKey, [stanza], plaintext);
        }
        finally
        {
            Array.Clear(fileKey);
            Array.Clear(ephemeral);
            Array.Clear(shared);
            Array.Clear(wrapKey);
        }
    }

    /// <summary>Encrypts <paramref name="plaintext"/> with a passphrase, as <c>age -p</c> does.</summary>
    public static byte[] EncryptWithPassphrase(byte[] plaintext, string passphrase, int workFactor = DefaultWorkFactor)
    {
        ArgumentNullException.ThrowIfNull(plaintext);
        ArgumentException.ThrowIfNullOrEmpty(passphrase);
        if (workFactor is < 1 or > MaxWorkFactor)
        {
            throw new ArgumentOutOfRangeException(nameof(workFactor), $"the work factor is from 1 to {MaxWorkFactor}: above it, age refuses the file");
        }
        byte[] fileKey = RandomNumberGenerator.GetBytes(FileKeySize);
        try
        {
            byte[] salt = RandomNumberGenerator.GetBytes(16);
            byte[] key = ScryptKey(passphrase, salt, workFactor);
            Stanza stanza = new(["scrypt", Base64(salt), workFactor.ToString(System.Globalization.CultureInfo.InvariantCulture)], Seal(key, fileKey));
            return Write(fileKey, [stanza], plaintext);
        }
        finally
        {
            Array.Clear(fileKey);
        }
    }

    /// <summary>Decrypts an age file with an X25519 identity.</summary>
    /// <exception cref="AgeException">The file is not an age file, is not for this identity, or was changed.</exception>
    public static byte[] Decrypt(byte[] file, string identity)
    {
        ArgumentNullException.ThrowIfNull(file);
        byte[] secret = ParseIdentity(identity);
        try
        {
            byte[] ourPublic = X25519.PublicKey(secret);
            return Decrypt(file, stanzas => UnwrapX25519(stanzas, secret, ourPublic));
        }
        finally
        {
            Array.Clear(secret);
        }
    }

    /// <summary>Decrypts an age file encrypted with a passphrase.</summary>
    /// <exception cref="AgeException">The file is not an age file, the passphrase is wrong, or the file was changed.</exception>
    public static byte[] DecryptWithPassphrase(byte[] file, string passphrase, int maxWorkFactor = MaxWorkFactor)
    {
        ArgumentNullException.ThrowIfNull(file);
        ArgumentException.ThrowIfNullOrEmpty(passphrase);
        return Decrypt(file, stanzas => UnwrapScrypt(stanzas, passphrase, maxWorkFactor));
    }

    private static byte[] ParseIdentity(string identity)
        => TryParseKey(identity, IdentityPrefix, KeyCase.Upper) ?? throw new ArgumentException("not an age identity (AGE-SECRET-KEY-1…)", nameof(identity));

    /// <summary>A recipient's point; null for anything else, a low-order point included.</summary>
    private static byte[]? ParseRecipient(string text)
    {
        byte[]? point = TryParseKey(text, RecipientPrefix, KeyCase.Lower);
        // Every clamped scalar is a multiple of the cofactor: a low-order point gives zero for all of them.
        return point is null || IsZero(X25519.ScalarMult(LowOrderProbe, point)) ? null : point;
    }

    private static readonly byte[] LowOrderProbe = SHA256.HashData("PSPhoenix low-order probe"u8);

    private enum KeyCase
    {
        Lower,
        Upper,
    }

    /// <summary>A key in one case only, as age writes and reads them: recipients lower, identities upper.</summary>
    private static byte[]? TryParseKey(string text, string prefix, KeyCase keyCase)
    {
        if (string.IsNullOrEmpty(text) || (keyCase == KeyCase.Lower ? text.Any(char.IsUpper) : text.Any(char.IsLower)))
        {
            return null;
        }
        (string Hrp, byte[] Data)? decoded = Bech32.Decode(text);
        return decoded is { } d && d.Hrp == prefix && d.Data.Length == X25519.Size ? d.Data : null;
    }

    private static bool IsZero(byte[] bytes)
    {
        int any = 0;
        foreach (byte b in bytes)
        {
            any |= b;
        }
        return any == 0;
    }

    private static byte[] ScryptKey(string passphrase, byte[] salt, int workFactor)
    {
        byte[] password = Encoding.UTF8.GetBytes(passphrase);
        try
        {
            return Scrypt.DeriveKey(password, [.. Encoding.ASCII.GetBytes(ScryptLabel), .. salt], workFactor, 8, 1, 32);
        }
        finally
        {
            Array.Clear(password);
        }
    }

    /// <summary>ChaCha20-Poly1305 with a zero nonce: what wraps a file key in a stanza.</summary>
    private static byte[] Seal(byte[] key, byte[] plaintext)
    {
        using ChaCha20Poly1305 aead = NewAead(key);
        byte[] sealedText = new byte[plaintext.Length + TagSize];
        aead.Encrypt(new byte[12], plaintext, sealedText.AsSpan(0, plaintext.Length), sealedText.AsSpan(plaintext.Length));
        return sealedText;
    }

    private static byte[]? Open(byte[] key, ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> sealedText)
    {
        if (sealedText.Length < TagSize)
        {
            return null;
        }
        using ChaCha20Poly1305 aead = NewAead(key);
        byte[] plaintext = new byte[sealedText.Length - TagSize];
        try
        {
            aead.Decrypt(nonce, sealedText[..^TagSize], sealedText[^TagSize..], plaintext);
            return plaintext;
        }
        catch (AuthenticationTagMismatchException)
        {
            return null;
        }
    }

    private static ChaCha20Poly1305 NewAead(byte[] key)
    {
        if (!ChaCha20Poly1305.IsSupported)
        {
            throw new PlatformNotSupportedException("this platform's .NET has no ChaCha20-Poly1305, which age needs");
        }
        return new ChaCha20Poly1305(key);
    }

    /// <summary>The header, its MAC, the nonce and the STREAM-encrypted payload.</summary>
    private static byte[] Write(byte[] fileKey, Stanza[] stanzas, byte[] plaintext)
    {
        StringBuilder header = new();
        header.Append(Version).Append('\n');
        foreach (Stanza stanza in stanzas)
        {
            header.Append("-> ").Append(string.Join(' ', stanza.Arguments)).Append('\n');
            string body = Base64(stanza.Body);
            for (int at = 0; ; at += 64)
            {
                if (body.Length - at >= 64)
                {
                    header.Append(body, at, 64).Append('\n');
                    continue;
                }
                // Every body ends with a line shorter than 64 columns, if need be an empty one.
                header.Append(body, at, body.Length - at).Append('\n');
                break;
            }
        }
        header.Append("---");
        byte[] mac = HeaderMac(fileKey, Encoding.ASCII.GetBytes(header.ToString()));
        header.Append(' ').Append(Base64(mac)).Append('\n');

        byte[] nonce = RandomNumberGenerator.GetBytes(NonceSize);
        byte[] payloadKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, fileKey, 32, nonce, "payload"u8.ToArray());
        using ClearOnDispose clear = new(payloadKey);
        using MemoryStream output = new();
        output.Write(Encoding.ASCII.GetBytes(header.ToString()));
        output.Write(nonce);
        using ChaCha20Poly1305 aead = NewAead(payloadKey);
        Span<byte> chunkNonce = stackalloc byte[12];
        int chunks = Math.Max(1, (plaintext.Length + ChunkSize - 1) / ChunkSize);
        for (int i = 0; i < chunks; i++)
        {
            int start = i * ChunkSize;
            int length = Math.Min(ChunkSize, plaintext.Length - start);
            StreamNonce(chunkNonce, i, last: i == chunks - 1);
            byte[] chunk = new byte[length + TagSize];
            aead.Encrypt(chunkNonce, plaintext.AsSpan(start, length), chunk.AsSpan(0, length), chunk.AsSpan(length));
            output.Write(chunk);
        }
        return output.ToArray();
    }

    private static byte[] HeaderMac(byte[] fileKey, byte[] header)
    {
        byte[] macKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, fileKey, 32, [], "header"u8.ToArray());
        try
        {
            return HMACSHA256.HashData(macKey, header);
        }
        finally
        {
            Array.Clear(macKey);
        }
    }

    /// <summary>The 12-byte STREAM nonce: an 11-byte big-endian counter and the last-chunk flag.</summary>
    private static void StreamNonce(Span<byte> nonce, long counter, bool last)
    {
        nonce.Clear();
        BinaryPrimitives.WriteInt64BigEndian(nonce[3..11], counter);
        nonce[11] = last ? (byte)1 : (byte)0;
    }

    private static byte[] Decrypt(byte[] file, Func<List<Stanza>, byte[]> unwrap)
    {
        Header header = ParseHeader(file);
        // An scrypt stanza is only ever alone: anything next to it could be used to tell whether a
        // guessed passphrase is the right one.
        if (header.Stanzas.Any(s => s.Arguments[0] == "scrypt") && header.Stanzas.Count != 1)
        {
            throw new AgeException(AgeFailure.Header, "an scrypt stanza must be the only one in the header");
        }
        byte[] fileKey = unwrap(header.Stanzas);
        try
        {
            if (!CryptographicOperations.FixedTimeEquals(HeaderMac(fileKey, file.AsSpan(0, header.MacStart).ToArray()), header.Mac))
            {
                throw new AgeException(AgeFailure.Hmac, "the header was changed: its MAC does not match");
            }
            if (file.Length - header.PayloadStart < NonceSize)
            {
                throw new AgeException(AgeFailure.Header, "the file ends before the payload's nonce");
            }
            byte[] nonce = file.AsSpan(header.PayloadStart, NonceSize).ToArray();
            byte[] payloadKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, fileKey, 32, nonce, "payload"u8.ToArray());
            try
            {
                return DecryptPayload(payloadKey, file.AsSpan(header.PayloadStart + NonceSize));
            }
            finally
            {
                Array.Clear(payloadKey);
            }
        }
        finally
        {
            Array.Clear(fileKey);
        }
    }

    /// <summary>STREAM decryption, chunk by chunk, as the age tool reads it.</summary>
    private static byte[] DecryptPayload(byte[] payloadKey, ReadOnlySpan<byte> payload)
    {
        using ChaCha20Poly1305 aead = NewAead(payloadKey);
        using MemoryStream released = new();
        Span<byte> nonce = stackalloc byte[12];
        int at = 0;
        for (long counter = 0; ; counter++)
        {
            int left = payload.Length - at;
            if (left == 0)
            {
                throw new AgeException(AgeFailure.Payload, counter == 0 ? "the payload is empty" : "the payload ends without its last chunk", released.ToArray());
            }
            int length = Math.Min(left, ChunkSize + TagSize);
            // A full chunk is read as one with more to come first, as the age tool reads it.
            bool last = left < ChunkSize + TagSize;
            ReadOnlySpan<byte> chunk = payload.Slice(at, length);
            byte[]? plaintext = TryOpenChunk(aead, nonce, counter, last, chunk);
            if (plaintext is null && !last)
            {
                // A full chunk can be the last one, with more data after it - which is then an error.
                last = true;
                plaintext = TryOpenChunk(aead, nonce, counter, last, chunk);
            }
            if (plaintext is null)
            {
                throw new AgeException(AgeFailure.Payload, "a payload chunk does not decrypt", released.ToArray());
            }
            if (last && plaintext.Length == 0 && counter > 0)
            {
                throw new AgeException(AgeFailure.Payload, "the last chunk is empty", released.ToArray());
            }
            released.Write(plaintext);
            at += length;
            if (last)
            {
                if (at != payload.Length)
                {
                    throw new AgeException(AgeFailure.Payload, "data after the last chunk", released.ToArray());
                }
                return released.ToArray();
            }
        }
    }

    private static byte[]? TryOpenChunk(ChaCha20Poly1305 aead, Span<byte> nonce, long counter, bool last, ReadOnlySpan<byte> chunk)
    {
        if (chunk.Length < TagSize)
        {
            return null;
        }
        StreamNonce(nonce, counter, last);
        byte[] plaintext = new byte[chunk.Length - TagSize];
        try
        {
            aead.Decrypt(nonce, chunk[..^TagSize], chunk[^TagSize..], plaintext);
            return plaintext;
        }
        catch (AuthenticationTagMismatchException)
        {
            return null;
        }
    }

    private static byte[] UnwrapX25519(List<Stanza> stanzas, byte[] secret, byte[] ourPublic)
    {
        foreach (Stanza stanza in stanzas.Where(s => s.Arguments[0] == "X25519"))
        {
            if (stanza.Arguments.Length != 2)
            {
                throw new AgeException(AgeFailure.Header, "an X25519 stanza takes one argument");
            }
            byte[] share = FromBase64(stanza.Arguments[1]) ?? throw new AgeException(AgeFailure.Header, "the X25519 share is not canonical base64");
            if (share.Length != X25519.Size)
            {
                throw new AgeException(AgeFailure.Header, "the X25519 share is not 32 bytes");
            }
            if (stanza.Body.Length != FileKeySize + TagSize)
            {
                throw new AgeException(AgeFailure.Header, "an X25519 stanza's body is not 32 bytes");
            }
            byte[] shared = X25519.ScalarMult(secret, share);
            if (IsZero(shared))
            {
                throw new AgeException(AgeFailure.Header, "the X25519 share is a low-order point");
            }
            byte[] wrapKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, [.. share, .. ourPublic], Encoding.ASCII.GetBytes(X25519Label));
            Array.Clear(shared);
            byte[]? fileKey = Open(wrapKey, new byte[12], stanza.Body);
            Array.Clear(wrapKey);
            if (fileKey is not null)
            {
                return fileKey;
            }
        }
        throw new AgeException(AgeFailure.NoMatch, "no stanza in the header is for this identity");
    }

    private static byte[] UnwrapScrypt(List<Stanza> stanzas, string passphrase, int maxWorkFactor)
    {
        foreach (Stanza stanza in stanzas.Where(s => s.Arguments[0] == "scrypt"))
        {
            if (stanza.Arguments.Length != 3)
            {
                throw new AgeException(AgeFailure.Header, "an scrypt stanza takes a salt and a work factor");
            }
            byte[] salt = FromBase64(stanza.Arguments[1]) ?? throw new AgeException(AgeFailure.Header, "the scrypt salt is not canonical base64");
            if (salt.Length != 16)
            {
                throw new AgeException(AgeFailure.Header, "the scrypt salt is not 16 bytes");
            }
            string factor = stanza.Arguments[2];
            if (factor.Length is 0 or > 2 || factor[0] is < '1' or > '9' || !factor.All(char.IsAsciiDigit))
            {
                throw new AgeException(AgeFailure.Header, "the scrypt work factor is not a plain decimal number");
            }
            int workFactor = int.Parse(factor, System.Globalization.CultureInfo.InvariantCulture);
            if (workFactor > maxWorkFactor || workFactor > 30)
            {
                throw new AgeException(AgeFailure.Header, $"the scrypt work factor {workFactor} is above {maxWorkFactor}");
            }
            if (stanza.Body.Length != FileKeySize + TagSize)
            {
                throw new AgeException(AgeFailure.Header, "an scrypt stanza's body is not 32 bytes");
            }
            byte[] key = ScryptKey(passphrase, salt, workFactor);
            byte[]? fileKey = Open(key, new byte[12], stanza.Body);
            Array.Clear(key);
            if (fileKey is not null)
            {
                return fileKey;
            }
        }
        throw new AgeException(AgeFailure.NoMatch, "the passphrase does not open this file");
    }

    /// <summary>The header, parsed strictly: anything the age format does not allow is a header failure.</summary>
    private static Header ParseHeader(byte[] file)
    {
        int at = 0;
        if (ReadLine(file, ref at) != Version)
        {
            throw new AgeException(AgeFailure.Header, "not an age v1 file");
        }
        List<Stanza> stanzas = [];
        while (true)
        {
            int lineStart = at;
            string line = ReadLine(file, ref at) ?? throw new AgeException(AgeFailure.Header, "the header ends without its MAC");
            if (line.StartsWith("---", StringComparison.Ordinal))
            {
                if (stanzas.Count == 0 || !line.StartsWith("--- ", StringComparison.Ordinal))
                {
                    throw new AgeException(AgeFailure.Header, "the header's MAC line is malformed");
                }
                byte[] mac = FromBase64(line[4..]) ?? throw new AgeException(AgeFailure.Header, "the header's MAC is not canonical base64");
                if (mac.Length != 32)
                {
                    throw new AgeException(AgeFailure.Header, "the header's MAC is not 32 bytes");
                }
                return new Header(stanzas, mac, lineStart + 3, at);
            }
            if (!line.StartsWith("-> ", StringComparison.Ordinal))
            {
                throw new AgeException(AgeFailure.Header, "a header line is neither a stanza nor the MAC");
            }
            string[] arguments = line[3..].Split(' ');
            if (arguments.Any(a => a.Length == 0 || a.Any(c => c is < (char)33 or > (char)126)))
            {
                throw new AgeException(AgeFailure.Header, "a stanza has an empty or invalid argument");
            }
            StringBuilder body = new();
            while (true)
            {
                string bodyLine = ReadLine(file, ref at) ?? throw new AgeException(AgeFailure.Header, "a stanza ends without its last body line");
                if (bodyLine.Length > 64 || !bodyLine.All(IsBase64Char))
                {
                    throw new AgeException(AgeFailure.Header, "a stanza body line is malformed");
                }
                body.Append(bodyLine);
                if (bodyLine.Length < 64)
                {
                    break;
                }
            }
            byte[] decoded = FromBase64(body.ToString()) ?? throw new AgeException(AgeFailure.Header, "a stanza body is not canonical base64");
            stanzas.Add(new Stanza(arguments, decoded));
        }
    }

    /// <summary>The next line up to (not including) LF, from ASCII bytes; null at the end of the file or on a byte outside printable ASCII.</summary>
    private static string? ReadLine(byte[] file, ref int at)
    {
        int end = Array.IndexOf(file, (byte)'\n', at);
        if (end < 0)
        {
            return null;
        }
        for (int i = at; i < end; i++)
        {
            if (file[i] is < 32 or > 126)
            {
                throw new AgeException(AgeFailure.Header, "the header holds a byte outside printable ASCII");
            }
        }
        string line = Encoding.ASCII.GetString(file, at, end - at);
        at = end + 1;
        return line;
    }

    private static bool IsBase64Char(char c) => char.IsAsciiLetterOrDigit(c) || c is '+' or '/';

    /// <summary>Standard base64 without padding, as age writes it.</summary>
    private static string Base64(byte[] data) => Convert.ToBase64String(data).TrimEnd('=');

    /// <summary>Strict unpadded base64: null for padding, a stray character or non-canonical trailing bits.</summary>
    private static byte[]? FromBase64(string text)
    {
        if (text.Length % 4 == 1 || !text.All(IsBase64Char))
        {
            return null;
        }
        string padded = text.PadRight(text.Length + ((4 - (text.Length % 4)) % 4), '=');
        byte[] data;
        try
        {
            data = Convert.FromBase64String(padded);
        }
        catch (FormatException)
        {
            return null;
        }
        return Base64(data) == text ? data : null;
    }

    private sealed record Stanza(string[] Arguments, byte[] Body);

    /// <summary>Clears a key when it goes out of scope (best effort: .NET may have copied it).</summary>
    private readonly struct ClearOnDispose(byte[] key) : IDisposable
    {
        public void Dispose() => Array.Clear(key);
    }

    private sealed record Header(List<Stanza> Stanzas, byte[] Mac, int MacStart, int PayloadStart);
}
