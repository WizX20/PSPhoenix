using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class SecretScannerTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private static readonly AgeKey AgeKey = Age.NewKey();

    /// <summary>A text with one secret, what it is, and the secret itself.</summary>
    public static TheoryData<string, string, SecretKind, string> OneSecret()
    {
        string github = Fake.GitHubToken();
        string hex = Fake.Random(Fake.Hex, 32);
        string base64 = Fake.Random(Fake.Base64, 40);
        string accountKey = Fake.Random(Fake.Base64, 86) + "==";
        TheoryData<string, string, SecretKind, string> data = new()
        {
            { "a classic GitHub token", $"token {github} in a note", SecretKind.GitHubToken, github },
            { "a fine-grained GitHub token", $"GH={Fake.GitHubFineGrainedToken()}", SecretKind.GitHubToken, Fake.GitHubFineGrainedToken() },
            { "a GitLab token", $"use {Fake.GitLabToken()}.", SecretKind.GitLabToken, Fake.GitLabToken() },
            { "a Slack token", $"\"bot\": \"{Fake.SlackToken()}\"", SecretKind.SlackToken, Fake.SlackToken() },
            { "an AWS access key", $"aws_access_key_id = {Fake.AwsAccessKey()}", SecretKind.AwsAccessKey, Fake.AwsAccessKey() },
            { "an npm token in .npmrc", $"//registry.npmjs.org/:_authToken={Fake.NpmToken()}", SecretKind.NpmToken, Fake.NpmToken() },
            { "an sk- API key", $"OPENAI_API_KEY={Fake.ApiKey()}", SecretKind.ApiKey, Fake.ApiKey() },
            { "an Azure DevOps token", $"pat {Fake.AzureDevOpsToken()} here", SecretKind.AzureDevOpsToken, Fake.AzureDevOpsToken() },
            { "a classic Azure DevOps token", $"azdo: {Fake.AzureDevOpsClassicToken()}", SecretKind.AzureDevOpsToken, Fake.AzureDevOpsClassicToken() },
            { "a JSON web token", $"Cookie: id={Fake.JsonWebToken()}", SecretKind.JsonWebToken, Fake.JsonWebToken() },
            { "a private key", $"key:\n{Fake.PrivateKey()}\nafter", SecretKind.PrivateKey, Fake.PrivateKey() },
            { "an OpenSSH private key", Fake.PrivateKey("OPENSSH"), SecretKind.PrivateKey, Fake.PrivateKey("OPENSSH") },
            { "a password in a URL", "git clone https://wouter:" + "hunter2" + "@example.com/r.git", SecretKind.UrlCredential, "hunter2" },
            { "a token as a URL's user name", $"https://{Fake.Random(Fake.Alphanumeric, 40)}@dev.azure.com/org", SecretKind.UrlCredential, Fake.Random(Fake.Alphanumeric, 40) },
            { "a GitHub token as a URL's user name", $"https://{github}@github.com/o/r", SecretKind.GitHubToken, github },
            { "an authorization header", $"http.extraheader=AUTHORIZATION: bearer {base64}", SecretKind.AuthorizationHeader, base64 },
            { "a password in a connection string", "Server=db;User Id=sa;Password=" + "S3cr3t!x" + ";Encrypt=true", SecretKind.Password, "S3cr3t!x" },
            { "a storage account key", $"DefaultEndpointsProtocol=https;AccountName=x;AccountKey={accountKey};EndpointSuffix=core.windows.net", SecretKind.SecretValue, accountKey },
            { "a NuGet ClearTextPassword", "<add key=\"ClearTextPassword\" value=\"" + "pa55word!" + "\" />", SecretKind.Password, "pa55word!" },
            { "a token in a PowerShell profile", $"$env:MY_API_TOKEN = '{hex}'", SecretKind.SecretValue, hex },
            { "a client secret in appsettings", $"  \"ClientSecret\": \"{base64}\",", SecretKind.SecretValue, base64 },
            { "an API key in YAML", $"api_key: {hex}", SecretKind.SecretValue, hex },
            { "a password in .env", "DB_PASSWORD=" + "hunter22", SecretKind.Password, "hunter22" },
            { "a password in an XML element", "<password>" + "hunter22" + "</password>", SecretKind.Password, "hunter22" },
            { "a GUID as an API key", "\"apiKey\": \"3f2504e0-4f89-11d3-9a0c-0305e82c3301\"", SecretKind.SecretValue, "3f2504e0-4f89-11d3-9a0c-0305e82c3301" },
            { "an age key file", $"# created: 2026-10-13T12:00:00Z\n# public key: {AgeKey.Recipient}\n{AgeKey.Identity}\n", SecretKind.AgeSecretKey, AgeKey.Identity },
            { "an age key in a variable", $"AGE_KEY={AgeKey.Identity}", SecretKind.AgeSecretKey, AgeKey.Identity },
        };
        return data;
    }

    [Theory]
    [MemberData(nameof(OneSecret))]
    public void Finds_one_secret_and_masks_exactly_it(string what, string text, SecretKind kind, string secret)
    {
        IReadOnlyList<SecretFinding> findings = SecretScanner.Scan(text);

        findings.Should().ContainSingle(what).Which.Kind.Should().Be(kind, what);
        string masked = SecretScanner.Mask(text);
        masked.Should().NotContain(secret, what);
        masked.Should().Be(text.Replace(secret, "***", StringComparison.Ordinal), what);
    }

    public static TheoryData<string, string> NoSecret()
    {
        string guid = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
        string sha512 = Convert.ToBase64String(Encoding.UTF8.GetBytes(Fake.Random(Fake.Alphanumeric, 64)));
        string image = Convert.ToBase64String(Enumerable.Range(0, 20000).Select(i => (byte)(i * 7919 % 251)).ToArray());
        TheoryData<string, string> data = new()
        {
            { "a GUID", $"\"ProjectGuid\": \"{{{guid}}}\", \"id\": \"{guid}\" {guid}" },
            { "a lock file's integrity", $"\"integrity\": \"sha512-{sha512}\", \"resolved\": \"https://registry.npmjs.org/x/-/x-1.0.0.tgz\"" },
            { "a NuGet lock file's content hash", $"\"contentHash\": \"{sha512}\"" },
            { "a checksum", $"checksum = \"{Fake.Random(Fake.Hex, 64)}\"" },
            { "a git SHA", $"commit {Fake.Random(Fake.Hex, 40)} on main" },
            { "a base64 image in JSON", $"{{ \"icon\": \"data:image/png;base64,{image}\" }}" },
            { "a reference to a variable", "\"token\": \"${GITHUB_TOKEN}\", Password=$(DbPassword); \"apiKey\": \"%API_KEY%\"" },
            { "a placeholder", "\"apiKey\": \"<your-api-key>\", \"password\": \"changeme\", \"token\": \"your-token-goes-here\"" },
            { "a masked value", "\"clientSecret\": \"xxxxxxxxxxxxxxxxxxxx\", \"password\": \"********\"" },
            { "an empty value", "\"ClientSecret\": \"\", Password=;" },
            { "a key that names no secret", $"\"tokenType\": \"Bearer\", \"tokenEndpoint\": \"https://login.example/token\", \"publicKey\": \"{Fake.Random(Fake.Base64, 40)}\"" },
            { "a git signing key id", "[user]\n\tsigningkey = 3AA5C34371567BD2" },
            { "a password policy", "\"passwordPolicy\": \"strong\", \"passwordLength\": 12" },
            { "a key binding", "{ \"key\": \"ctrl+shift+p\", \"command\": \"workbench.action.showCommands\" }" },
            { "a short or repetitive token", "\"token\": \"abc\", \"apiKey\": \"aaaaaaaaaaaaaaaa\"" },
            { "a path to a key", "\"privateKey\": \"~/.ssh/id_ed25519\", \"credentials\": \"C:\\\\Users\\\\x\\\\.aws\\\\credentials\"" },
            { "a URL without credentials", "https://org@dev.azure.com/org ssh://git@github.com/o/r.git git@github.com:o/r.git" },
            { "an age recipient: the public half", $"\"recipient\": \"{AgeKey.Recipient}\" # public key: {AgeKey.Recipient}" },
            { "prose about passwords", "The password policy requires twelve characters. Note: token: see the docs." },
            { "words that start like a key", "task-runner-configuration sk-learn-preprocessing-pipeline" },
        };
        return data;
    }

    [Theory]
    [MemberData(nameof(NoSecret))]
    public void Finds_no_secret_in(string what, string text)
    {
        SecretScanner.Scan(text).Should().BeEmpty(what);
        SecretScanner.Mask(text).Should().Be(text);
    }

    [Fact]
    public void A_value_under_a_secret_key_counts_from_twelve_random_characters()
    {
        SecretScanner.Scan($"token: {Fake.Random(Fake.Base64, 12)}").Should().ContainSingle().Which.Kind.Should().Be(SecretKind.SecretValue);
        SecretScanner.Scan($"token: {Fake.Random(Fake.Base64, 11)}").Should().BeEmpty();
        // Random hex of 32, the shortest common token, clears the entropy bar every time.
        Enumerable.Range(1, 200).Select(seed => SecretScanner.Entropy(Fake.Random(Fake.Hex, 32, seed))).Min().Should().BeGreaterThanOrEqualTo(SecretScanner.MinimumEntropy);
    }

    [Fact]
    public void A_value_under_a_password_key_counts_whatever_it_looks_like()
    {
        SecretScanner.Scan("\"password\": \"" + "Winter2024!" + "\"").Should().ContainSingle().Which.Kind.Should().Be(SecretKind.Password);
        SecretScanner.Scan("passphrase = " + "\"correct horse battery staple\"").Should().ContainSingle().Which.Kind.Should().Be(SecretKind.Password);
    }

    [Fact]
    public void Reports_line_column_and_key_but_never_the_value()
    {
        string text = "{\n  \"name\": \"x\",\n  \"ClientSecret\": \"" + Fake.Random(Fake.Base64, 40) + "\",\n  \"t\": \"" + Fake.GitHubToken() + "\"\n}";

        IReadOnlyList<SecretFinding> findings = SecretScanner.Scan(text);

        findings.Should().HaveCount(2);
        findings[0].Should().Be(new SecretFinding(SecretKind.SecretValue, 3, 20, "ClientSecret") { Index = findings[0].Index, Length = 40 });
        findings[0].Description.Should().Be("a secret value (ClientSecret)");
        findings[1].Kind.Should().Be(SecretKind.GitHubToken);
        findings[1].Line.Should().Be(4);
        findings[1].Column.Should().Be(9);
        findings[1].Description.Should().Be("a GitHub token");
        findings.Select(f => f.ToString()).Should().AllSatisfy(s => s.Should().NotContain(Fake.GitHubToken()));
    }

    [Fact]
    public void Masks_several_secrets_and_keeps_the_rest()
    {
        string text = $"a {Fake.GitHubToken()} b https://user:" + "pw" + $"@host c {Fake.GitLabToken()}";

        SecretScanner.Mask(text).Should().Be("a *** b https://user:***@host c ***");
    }

    [Fact]
    public void A_private_key_without_its_end_is_masked_to_the_end()
    {
        string text = "before\n-----BEGIN PRIVATE" + " KEY-----\n" + Fake.Random(Fake.Base64, 64);

        SecretScanner.Mask(text).Should().Be("before\n***");
    }

    [Theory]
    [InlineData("ClearTextPassword", new[] { "clear", "text", "password" })]
    [InlineData("GITHUB_TOKEN", new[] { "github", "token" })]
    [InlineData("_authToken", new[] { "auth", "token" })]
    [InlineData("APIKey", new[] { "api", "key" })]
    [InlineData("x-api-key", new[] { "x", "api", "key" })]
    [InlineData("SharedAccessKey", new[] { "shared", "access", "key" })]
    [InlineData("user.signingkey", new[] { "user", "signingkey" })]
    public void Splits_a_key_into_words(string key, string[] words)
        => SecretScanner.Words(key).Should().Equal(words);

    [Theory]
    [InlineData("ghp_", true)]
    [InlineData("glpat-", true)]
    [InlineData("opaque", true)]
    [InlineData("short", false)]
    [InlineData("with:colon", false)]
    public void Tells_a_user_name_that_is_a_token(string kind, bool tokenLike)
    {
        string value = kind switch
        {
            "ghp_" => Fake.GitHubToken(),
            "glpat-" => Fake.GitLabToken(),
            "opaque" => Fake.Random(Fake.Alphanumeric, 52),
            "short" => "wouter",
            _ => Fake.Random(Fake.Alphanumeric, 20) + ":" + Fake.Random(Fake.Alphanumeric, 20),
        };

        SecretScanner.IsTokenLike(value).Should().Be(tokenLike);
    }

    [Fact]
    public void ScanFile_finds_secrets_in_utf8_and_utf16_files()
    {
        string utf8 = temp["settings.json"];
        File.WriteAllText(utf8, $"{{ \"token\": \"{Fake.GitHubToken()}\" }}", new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        string utf16 = temp["profile.ps1"];
        File.WriteAllText(utf16, $"\n$env:GH_TOKEN = '{Fake.GitHubToken()}'", Encoding.Unicode);

        SecretScanner.ScanFile(utf8).IsBinary.Should().BeFalse();
        SecretScanner.ScanFile(utf8).Findings.Should().ContainSingle().Which.Should().Match<SecretFinding>(f => f.Kind == SecretKind.GitHubToken && f.Line == 1 && f.Column == 13);
        SecretScanner.ScanFile(utf16).Findings.Should().ContainSingle().Which.Line.Should().Be(2);
    }

    [Fact]
    public void ScanFile_does_not_scan_a_binary_file()
    {
        string path = temp["key.pfx"];
        File.WriteAllBytes(path, [.. Encoding.ASCII.GetBytes(Fake.GitHubToken()), 0, 1, 2]);

        FileScan scan = SecretScanner.ScanFile(path);

        scan.IsBinary.Should().BeTrue();
        scan.HasSecret.Should().BeFalse();
    }

    [Fact]
    public void ScanFile_refuses_a_relative_path_and_throws_for_a_missing_file()
    {
        ((Action)(() => SecretScanner.ScanFile("settings.json"))).Should().Throw<ArgumentException>();
        ((Action)(() => SecretScanner.ScanFile(temp["missing.json"]))).Should().Throw<FileNotFoundException>();
    }

    [Fact]
    public void Scans_a_megabyte_of_text_quickly()
    {
        StringBuilder text = new();
        for (int i = 0; text.Length < 1_000_000; i++)
        {
            text.Append(CultureInfo.InvariantCulture, $"  \"key{i}\": \"{Fake.Random(Fake.Base64, 60, i)}\", \"path\": \"C:/x/{i}\", url = https://h/{i}\n");
        }
        Stopwatch watch = Stopwatch.StartNew();

        SecretScanner.Scan(text.ToString());

        watch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(10));
    }
}
