using System.Text;
using System.Text.RegularExpressions;

namespace PSPhoenix.Engine;

/// <summary>What kind of secret a <see cref="SecretFinding"/> is.</summary>
public enum SecretKind
{
    /// <summary>A <c>-----BEGIN … PRIVATE KEY-----</c> block.</summary>
    PrivateKey,

    /// <summary><c>ghp_</c>, <c>gho_</c>, <c>ghu_</c>, <c>ghs_</c>, <c>ghr_</c>, <c>github_pat_</c>.</summary>
    GitHubToken,

    /// <summary><c>glpat-</c>.</summary>
    GitLabToken,

    /// <summary><c>xoxa-</c>, <c>xoxb-</c>, <c>xoxp-</c>, <c>xoxr-</c>, <c>xoxs-</c>.</summary>
    SlackToken,

    /// <summary><c>AKIA…</c> or <c>ASIA…</c>.</summary>
    AwsAccessKey,

    /// <summary><c>sk-…</c>: OpenAI, Anthropic and others.</summary>
    ApiKey,

    /// <summary>An Azure DevOps personal access token.</summary>
    AzureDevOpsToken,

    /// <summary><c>npm_…</c>.</summary>
    NpmToken,

    /// <summary>A JSON web token: <c>eyJ….eyJ….…</c>.</summary>
    JsonWebToken,

    /// <summary>An age secret key: <c>AGE-SECRET-KEY-1…</c> - what opens a snapshot's secrets.</summary>
    AgeSecretKey,

    /// <summary>A password in a URL (<c>user:password@</c>), or a token as its user name.</summary>
    UrlCredential,

    /// <summary><c>Authorization: Bearer …</c>, <c>Basic …</c> or <c>token …</c>.</summary>
    AuthorizationHeader,

    /// <summary>A value assigned to a password-like key: <c>Password=</c>, <c>"pwd":</c>, <c>ClearTextPassword</c>.</summary>
    Password,

    /// <summary>A random-looking value assigned to a secret-like key: <c>token</c>, <c>apiKey</c>, <c>clientSecret</c>, <c>AccountKey</c>.</summary>
    SecretValue,

    /// <summary>Text the scan could not finish: treated as a secret, never as clean.</summary>
    Unscannable,
}

/// <summary>
/// One secret in a text: where it is and what kind - never the value itself, so a finding can go
/// into a log, a warning or <c>phx status</c> as it is.
/// </summary>
/// <param name="Kind">What kind of secret.</param>
/// <param name="Line">Its line, from 1.</param>
/// <param name="Column">Its column, from 1.</param>
/// <param name="Key">The key it is assigned to, for <see cref="SecretKind.Password"/> and <see cref="SecretKind.SecretValue"/>.</param>
public sealed record SecretFinding(SecretKind Kind, int Line, int Column, string? Key = null)
{
    /// <summary>Where the value starts in the text scanned.</summary>
    internal int Index { get; init; }

    /// <summary>How long the value is.</summary>
    internal int Length { get; init; }

    /// <summary>The kind in words, with the key when there is one: <c>a GitHub token</c>, <c>a password (Password)</c>.</summary>
    public string Description => Key is null ? SecretScanner.Describe(Kind) : $"{SecretScanner.Describe(Kind)} ({Key})";
}

/// <summary>What <see cref="SecretScanner.ScanFile"/> found in a file.</summary>
/// <param name="IsBinary">Not text - a NUL in its first 8000 bytes, as git decides - so not scanned.</param>
/// <param name="Findings">The secrets in it, in order.</param>
public sealed record FileScan(bool IsBinary, IReadOnlyList<SecretFinding> Findings)
{
    /// <summary>Whether the file holds a secret.</summary>
    public bool HasSecret => Findings.Count > 0;
}

/// <summary>
/// Finds secrets in text by their content (docs/design.md -> Secrets): tokens by their published
/// formats, private keys, credentials in URLs and authorization headers, and values assigned to
/// keys that name a password or a secret. The one detector PSPhoenix has: the staging writer, the
/// repository inventory and the masking of logs and error messages all ask here.
/// </summary>
/// <remarks>
/// A value under a password-like key is a secret whatever it looks like - a human password has
/// little entropy. A value under a token- or key-like key is one when it looks random: at least
/// <see cref="MinimumSecretLength"/> characters without whitespace, at least
/// <see cref="MinimumEntropy"/> bits of entropy per character. Placeholders (<c>${TOKEN}</c>,
/// <c>&lt;your-key&gt;</c>, <c>changeme</c>), paths and URLs are not secrets. In doubt, a value
/// counts as a secret: it is then only stored encrypted, which costs little.
/// </remarks>
public static partial class SecretScanner
{
    /// <summary>The shortest value under a secret-like key that counts as a secret.</summary>
    public const int MinimumSecretLength = 12;

    /// <summary>The least entropy, in bits per character, of a value under a secret-like key that counts as a secret.</summary>
    public const double MinimumEntropy = 3.0;

    private const int Timeout = 2000;
    private const RegexOptions Options = RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture;

    /// <summary>Known formats, most specific first: a span two of them find goes to the first.</summary>
    private static readonly Rule[] Formats =
    [
        new(SecretKind.PrivateKey, PrivateKeyPattern()),
        new(SecretKind.AgeSecretKey, AgeSecretKeyPattern()),
        new(SecretKind.GitHubToken, GitHubPattern()),
        new(SecretKind.GitLabToken, GitLabPattern()),
        new(SecretKind.SlackToken, SlackPattern()),
        new(SecretKind.AwsAccessKey, AwsPattern()),
        new(SecretKind.NpmToken, NpmPattern()),
        new(SecretKind.ApiKey, ApiKeyPattern(), value => Entropy(value) >= MinimumEntropy && value.Any(char.IsDigit)),
        new(SecretKind.AzureDevOpsToken, AzureDevOpsPattern()),
        new(SecretKind.AzureDevOpsToken, AzureDevOpsClassicPattern(), value => value.Any(char.IsDigit)),
        new(SecretKind.JsonWebToken, JwtPattern()),
        new(SecretKind.UrlCredential, UrlPasswordPattern(), value => !IsReference(value)),
        new(SecretKind.UrlCredential, UrlUserPattern(), IsTokenLike),
        new(SecretKind.AuthorizationHeader, AuthorizationPattern(), value => !IsReference(value)),
    ];

    /// <summary>Where a text assigns a value to a key: JSON, XML, and key = value or key: value.</summary>
    private static readonly Regex[] Assignments = [JsonPairPattern(), XmlAddPattern(), XmlElementPattern(), AssignmentPattern()];

    private static readonly HashSet<string> PasswordWords = new(StringComparer.Ordinal) { "password", "passwd", "pwd", "pass", "passphrase" };
    private static readonly HashSet<string> SecretWords = new(StringComparer.Ordinal) { "secret", "secrets", "token", "pat", "apikey", "auth", "credential", "credentials", "sas" };
    private static readonly string[] SecretSuffixes = ["password", "passwd", "passphrase", "secret", "token", "apikey", "accesskey", "secretkey", "privatekey", "accountkey"];
    private static readonly HashSet<string> KeyQualifiers = new(StringComparer.Ordinal)
    {
        "api", "access", "secret", "private", "account", "client", "master", "shared", "subscription", "storage", "auth", "encryption", "service", "app",
    };
    private static readonly HashSet<string> Placeholders = new(StringComparer.Ordinal)
    {
        "password", "passwd", "secret", "token", "apikey", "changeme", "change-me", "change_me", "changeit", "example", "sample", "test",
        "dummy", "null", "nil", "none", "true", "false", "required", "optional", "string", "todo", "tbd", "placeholder", "redacted",
        "hidden", "empty", "default", "value", "undefined",
    };

    /// <summary>Every secret in <paramref name="text"/>, in order.</summary>
    public static IReadOnlyList<SecretFinding> Scan(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        List<Span> spans = [];
        try
        {
            int priority = 0;
            foreach (Rule rule in Formats)
            {
                foreach (Match match in rule.Pattern.Matches(text))
                {
                    Group value = match.Groups["value"];
                    (int index, int length) = value.Success ? (value.Index, value.Length) : (match.Index, match.Length);
                    if (length > 0 && (rule.Accept is null || rule.Accept(text.Substring(index, length))))
                    {
                        spans.Add(new Span(index, length, rule.Kind, null, priority));
                    }
                }
                priority++;
            }
            foreach (Regex pattern in Assignments)
            {
                foreach (Match match in pattern.Matches(text))
                {
                    string key = match.Groups["key"].Value;
                    Group value = match.Groups["value"];
                    SecretKind? kind = Classify(key, value.Value);
                    if (kind is not null)
                    {
                        spans.Add(new Span(value.Index, value.Length, kind.Value, key, priority));
                    }
                }
            }
        }
        catch (RegexMatchTimeoutException)
        {
            // Fail closed: a text the scan could not finish is not taken for clean.
            return [new SecretFinding(SecretKind.Unscannable, 1, 1) { Index = 0, Length = text.Length }];
        }
        return ToFindings(text, spans);
    }

    /// <summary>
    /// <paramref name="text"/> with every secret in it replaced by <c>***</c>: for a log line, an
    /// error message, a warning. A password in a URL keeps its user name (<c>user:***@</c>).
    /// </summary>
    public static string Mask(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        IReadOnlyList<SecretFinding> findings = Scan(text);
        if (findings.Count == 0)
        {
            return text;
        }
        StringBuilder masked = new(text.Length);
        int at = 0;
        foreach (SecretFinding finding in findings)
        {
            masked.Append(text, at, finding.Index - at).Append("***");
            at = finding.Index + finding.Length;
        }
        return masked.Append(text, at, text.Length - at).ToString();
    }

    /// <summary>
    /// The secrets in a file. A binary file (a NUL in its first 8000 bytes, as git decides) is not
    /// scanned; UTF-8 and UTF-16 with a byte order mark are read as such, anything else as UTF-8.
    /// </summary>
    public static FileScan ScanFile(string path)
    {
        AtomicFile.RequireFullPath(path);
        string? text = Decode(ReadShared(path));
        return text is null ? new FileScan(true, []) : new FileScan(false, Scan(text));
    }

    /// <summary>A file's bytes, read alongside writers and deleters - a file another program has open must not fail the read.</summary>
    internal static byte[] ReadShared(string path)
    {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        byte[] bytes = new byte[stream.Length];
        stream.ReadExactly(bytes);
        return bytes;
    }

    /// <summary>
    /// A user name that is itself a credential: a token with a known prefix, or a long opaque string
    /// such as an Azure DevOps PAT.
    /// </summary>
    public static bool IsTokenLike(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return TokenPrefixPattern().IsMatch(value) || (value.Length >= 32 && OpaquePattern().IsMatch(value));
    }

    /// <summary>A kind in words: <c>a GitHub token</c>.</summary>
    public static string Describe(SecretKind kind) => kind switch
    {
        SecretKind.PrivateKey => "a private key",
        SecretKind.GitHubToken => "a GitHub token",
        SecretKind.GitLabToken => "a GitLab token",
        SecretKind.SlackToken => "a Slack token",
        SecretKind.AwsAccessKey => "an AWS access key",
        SecretKind.ApiKey => "an API key",
        SecretKind.AzureDevOpsToken => "an Azure DevOps token",
        SecretKind.NpmToken => "an npm token",
        SecretKind.JsonWebToken => "a JSON web token",
        SecretKind.AgeSecretKey => "an age secret key",
        SecretKind.UrlCredential => "credentials in a URL",
        SecretKind.AuthorizationHeader => "an authorization header",
        SecretKind.Password => "a password",
        SecretKind.SecretValue => "a secret value",
        SecretKind.Unscannable => "text the secret scan could not finish",
        _ => kind.ToString(),
    };

    /// <summary>Shannon entropy in bits per character.</summary>
    internal static double Entropy(string value)
    {
        if (value.Length == 0)
        {
            return 0;
        }
        Dictionary<char, int> counts = [];
        foreach (char c in value)
        {
            counts[c] = counts.GetValueOrDefault(c) + 1;
        }
        double entropy = 0;
        foreach (int count in counts.Values)
        {
            double p = (double)count / value.Length;
            entropy -= p * Math.Log2(p);
        }
        return entropy;
    }

    /// <summary>
    /// What a value assigned to <paramref name="key"/> is: a password, a secret value, or nothing.
    /// The key's last word decides - <c>accessToken</c> names a token, <c>tokenType</c> a type.
    /// </summary>
    internal static SecretKind? Classify(string key, string value)
    {
        List<string> words = Words(key);
        if (words.Count == 0 || IsPlaceholder(value) || IsPathOrUrl(value))
        {
            return null;
        }
        string last = words[^1];
        string? previous = words.Count > 1 ? words[^2] : null;
        if (PasswordWords.Contains(last) || last.EndsWith("password", StringComparison.Ordinal) || last.EndsWith("passwd", StringComparison.Ordinal) || last.EndsWith("passphrase", StringComparison.Ordinal))
        {
            return value.Trim().Length >= 3 ? SecretKind.Password : null;
        }
        bool secretKey = SecretWords.Contains(last)
            || SecretSuffixes.Any(suffix => last.EndsWith(suffix, StringComparison.Ordinal))
            || (last == "key" && previous is not null && KeyQualifiers.Contains(previous))
            || (last == "signature" && previous == "access");
        if (!secretKey)
        {
            return null;
        }
        return value.Length >= MinimumSecretLength && !value.Any(char.IsWhiteSpace) && Entropy(value) >= MinimumEntropy
            ? SecretKind.SecretValue
            : null;
    }

    /// <summary>A key's words, lower-cased: <c>ClearTextPassword</c> -> clear, text, password; <c>GITHUB_TOKEN</c> -> github, token.</summary>
    internal static List<string> Words(string key)
    {
        List<string> words = [];
        StringBuilder word = new();
        for (int i = 0; i < key.Length; i++)
        {
            char c = key[i];
            if (!char.IsLetterOrDigit(c))
            {
                Flush();
                continue;
            }
            bool boundary = word.Length > 0 && char.IsUpper(c)
                && (char.IsLower(key[i - 1]) || char.IsDigit(key[i - 1]) || (char.IsUpper(key[i - 1]) && i + 1 < key.Length && char.IsLower(key[i + 1])));
            if (boundary)
            {
                Flush();
            }
            word.Append(char.ToLowerInvariant(c));
        }
        Flush();
        return words;

        void Flush()
        {
            if (word.Length > 0)
            {
                words.Add(word.ToString());
                word.Clear();
            }
        }
    }

    /// <summary>A reference to a secret kept elsewhere: <c>${TOKEN}</c>, <c>$(Token)</c>, <c>%PASSWORD%</c>, <c>{{key}}</c>, <c>&lt;key&gt;</c>.</summary>
    internal static bool IsReference(string value)
    {
        string v = value.Trim();
        return v.Length == 0 || v[0] is '$' or '%' or '<' or '{' or '[' || v.StartsWith("@Microsoft.KeyVault(", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>A value that stands for a secret rather than being one: a reference, <c>your-key</c>, <c>changeme</c>, <c>***</c>.</summary>
    internal static bool IsPlaceholder(string value)
    {
        string v = value.Trim();
        if (IsReference(v))
        {
            return true;
        }
        if (v.Contains("***", StringComparison.Ordinal) || v.Contains("xxx", StringComparison.OrdinalIgnoreCase) || v.Contains("...", StringComparison.Ordinal))
        {
            return true;
        }
        string lower = v.ToLowerInvariant();
        return Placeholders.Contains(lower)
            || lower.StartsWith("your", StringComparison.Ordinal)
            || lower.Contains("replace", StringComparison.Ordinal)
            || lower.Contains("placeholder", StringComparison.Ordinal)
            || lower.EndsWith("here", StringComparison.Ordinal);
    }

    /// <summary>A path or a URL: where a secret is, not the secret.</summary>
    private static bool IsPathOrUrl(string value)
    {
        string v = value.Trim();
        return v.Contains("://", StringComparison.Ordinal)
            || v.StartsWith('/') || v.StartsWith("./", StringComparison.Ordinal) || v.StartsWith("../", StringComparison.Ordinal)
            || v.StartsWith("~/", StringComparison.Ordinal) || v.StartsWith(@"~\", StringComparison.Ordinal) || v.StartsWith(@"\\", StringComparison.Ordinal)
            || (v.Length >= 3 && char.IsAsciiLetter(v[0]) && v[1] == ':' && v[2] is '\\' or '/');
    }

    /// <summary>Text from a file's bytes; null for a binary file.</summary>
    internal static string? Decode(byte[] bytes)
    {
        if (bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]))
        {
            return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        }
        if (bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xFF, 0xFE]))
        {
            return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        }
        if (bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xFE, 0xFF]))
        {
            return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
        }
        return bytes.AsSpan(0, Math.Min(bytes.Length, 8000)).Contains((byte)0) ? null : Encoding.UTF8.GetString(bytes);
    }

    /// <summary>The spans as findings: overlaps go to the most specific rule, then in text order with line and column.</summary>
    private static List<SecretFinding> ToFindings(string text, List<Span> spans)
    {
        List<Span> kept = [];
        foreach (Span span in spans.OrderBy(s => s.Priority).ThenBy(s => s.Index).ThenByDescending(s => s.Length))
        {
            if (!kept.Any(k => span.Index < k.Index + k.Length && k.Index < span.Index + span.Length))
            {
                kept.Add(span);
            }
        }
        List<int> lineStarts = [0];
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '\n')
            {
                lineStarts.Add(i + 1);
            }
        }
        List<SecretFinding> findings = [];
        foreach (Span span in kept.OrderBy(s => s.Index))
        {
            int line = lineStarts.BinarySearch(span.Index);
            line = line >= 0 ? line : ~line - 1;
            findings.Add(new SecretFinding(span.Kind, line + 1, span.Index - lineStarts[line] + 1, span.Key) { Index = span.Index, Length = span.Length });
        }
        return findings;
    }

    private sealed record Rule(SecretKind Kind, Regex Pattern, Func<string, bool>? Accept = null);

    private sealed record Span(int Index, int Length, SecretKind Kind, string? Key, int Priority);

    [GeneratedRegex(@"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|\z)", Options, Timeout)]
    private static partial Regex PrivateKeyPattern();

    [GeneratedRegex(@"(?i)(?<![A-Za-z0-9_-])AGE-SECRET-KEY-(?:PQ-)?1[0-9A-Z]{40,}", Options, Timeout)]
    private static partial Regex AgeSecretKeyPattern();

    [GeneratedRegex(@"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})", Options, Timeout)]
    private static partial Regex GitHubPattern();

    [GeneratedRegex(@"(?<![A-Za-z0-9_-])glpat-[A-Za-z0-9_-]{20,}", Options, Timeout)]
    private static partial Regex GitLabPattern();

    [GeneratedRegex(@"(?<![A-Za-z0-9_-])xox[abprs]-[A-Za-z0-9-]{10,}", Options, Timeout)]
    private static partial Regex SlackPattern();

    [GeneratedRegex(@"(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])", Options, Timeout)]
    private static partial Regex AwsPattern();

    [GeneratedRegex(@"(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])", Options, Timeout)]
    private static partial Regex NpmPattern();

    [GeneratedRegex(@"(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}", Options, Timeout)]
    private static partial Regex ApiKeyPattern();

    // The format since 2024: 84 characters with the signature AZDO near the end.
    [GeneratedRegex(@"(?<![A-Za-z0-9])[A-Za-z0-9]{76}AZDO[A-Za-z0-9]{4}(?![A-Za-z0-9])", Options, Timeout)]
    private static partial Regex AzureDevOpsPattern();

    // The classic format: 52 characters of base32, lower case.
    [GeneratedRegex(@"(?<![A-Za-z0-9])[a-z2-7]{52}(?![A-Za-z0-9])", Options, Timeout)]
    private static partial Regex AzureDevOpsClassicPattern();

    [GeneratedRegex(@"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", Options, Timeout)]
    private static partial Regex JwtPattern();

    [GeneratedRegex(@"[A-Za-z][A-Za-z0-9+.-]*://[^/@:\s'""]*:(?<value>[^/@\s'""]+)@", Options, Timeout)]
    private static partial Regex UrlPasswordPattern();

    [GeneratedRegex(@"[A-Za-z][A-Za-z0-9+.-]*://(?<value>[^/@:\s'""]+)@", Options, Timeout)]
    private static partial Regex UrlUserPattern();

    [GeneratedRegex(@"(?i)\bauthorization[""']?\s*[:=]\s*[""']?(?:bearer|basic|token)\s+(?<value>[A-Za-z0-9+/=._~-]{8,})", Options, Timeout)]
    private static partial Regex AuthorizationPattern();

    // "key": "value" (JSON), 'key': 'value'.
    [GeneratedRegex(@"(?<kq>[""'])(?<key>[^""'\r\n]{1,100})\k<kq>\s*:\s*(?<vq>[""'])(?<value>(?:\\.|(?!\k<vq>)[^\\\r\n])*)\k<vq>", Options, Timeout)]
    private static partial Regex JsonPairPattern();

    // <add key="ApiKey" value="..." /> (appSettings, nuget.config).
    [GeneratedRegex(@"(?i)\bkey\s*=\s*""(?<key>[^""\r\n]{1,100})""\s+value\s*=\s*""(?<value>[^""\r\n]*)""", Options, Timeout)]
    private static partial Regex XmlAddPattern();

    // <Password>value</Password>.
    [GeneratedRegex(@"<(?<key>[A-Za-z_][\w.-]{0,100})>(?<value>[^<\r\n]+)</\k<key>>", Options, Timeout)]
    private static partial Regex XmlElementPattern();

    // key = value, key: value (not ://), $env:KEY = 'value', Password=value; in a connection string.
    [GeneratedRegex(@"(?<![\w.$-])(?:\$env:)?(?<key>[A-Za-z_][\w.-]{0,100})[ \t]*(?:=|:(?!//))[ \t]*(?:(?<vq>[""'])(?<value>(?:(?!\k<vq>)[^\r\n])*)\k<vq>|(?<value>[^\s;""',<>#]+))", Options, Timeout)]
    private static partial Regex AssignmentPattern();

    [GeneratedRegex(@"^(?:gh[pousr]_|github_pat_|glpat-|xox[abprs]-|npm_|sk-)", Options, Timeout)]
    private static partial Regex TokenPrefixPattern();

    [GeneratedRegex(@"^[A-Za-z0-9_-]+$", Options, Timeout)]
    private static partial Regex OpaquePattern();
}
