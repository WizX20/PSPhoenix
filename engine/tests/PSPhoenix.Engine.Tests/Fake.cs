namespace PSPhoenix.Engine.Tests;

/// <summary>
/// Fake secrets, built when the tests run: nothing token-like is committed, so no secret scanner -
/// GitHub's push protection included - mistakes the repository for a leak. Random with a fixed seed,
/// so a test sees the same values every run.
/// </summary>
internal static class Fake
{
    public const string Alphanumeric = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    public const string Base64 = Alphanumeric + "+/";
    public const string Hex = "0123456789abcdef";

    /// <summary><paramref name="length"/> characters from <paramref name="alphabet"/>.</summary>
    public static string Random(string alphabet, int length, int seed = 1)
    {
        Random random = new(seed);
        return new string(Enumerable.Range(0, length).Select(_ => alphabet[random.Next(alphabet.Length)]).ToArray());
    }

    public static string GitHubToken(int seed = 1) => "gh" + "p_" + Random(Alphanumeric, 36, seed);

    public static string GitHubFineGrainedToken() => "github" + "_pat_" + Random(Alphanumeric + "_", 82);

    public static string GitLabToken() => "gl" + "pat-" + Random(Alphanumeric, 20);

    public static string SlackToken() => "xo" + "xb-" + Random("0123456789", 12) + "-" + Random(Alphanumeric, 24);

    public static string AwsAccessKey() => "AK" + "IA" + Random("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", 16);

    public static string NpmToken() => "np" + "m_" + Random(Alphanumeric, 36);

    public static string ApiKey() => "s" + "k-proj-" + Random(Alphanumeric, 48);

    public static string AzureDevOpsToken() => Random(Alphanumeric, 76) + "AZ" + "DO" + Random(Alphanumeric, 4);

    public static string AzureDevOpsClassicToken() => Random("abcdefghijklmnopqrstuvwxyz234567", 51) + "7";

    public static string JsonWebToken()
        => "ey" + "J" + Random(Alphanumeric, 20) + ".ey" + "J" + Random(Alphanumeric, 40) + "." + Random(Alphanumeric + "-_", 43);

    public static string PrivateKey(string type = "RSA")
        => $"-----BEGIN {type} PRIVATE" + " KEY-----\n" + Random(Base64, 64) + "\n" + Random(Base64, 64, 2) + "\n" + $"-----END {type} PRIVATE KEY-----";
}
