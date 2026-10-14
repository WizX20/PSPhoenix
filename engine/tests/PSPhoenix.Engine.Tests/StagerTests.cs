using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class StagerTests : IDisposable
{
    private static readonly AgeKey Key = Age.NewKey();
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private Stager NewStager(bool key = true) => new(temp["staging"], key ? new Sealer(Key.Recipient, temp["sealed"]) : null);

    [Fact]
    public void Records_what_each_file_became()
    {
        Stager stager = NewStager();

        stager.WriteText(temp["staging", "a", "clean.txt"], "nothing here");
        stager.WriteText(temp["staging", "token.txt"], "token " + Fake.GitHubToken());

        stager.Entries.Select(e => (e.Path, e.Stored, e.As)).Should().Equal(
            ("a/clean.txt", "a/clean.txt", StagedAs.Plain),
            ("token.txt", "token.txt.age", StagedAs.Sealed));
        stager.Find("token.txt")!.Findings.Should().ContainSingle().Which.Kind.Should().Be(SecretKind.GitHubToken);
    }

    [Fact]
    public void Without_a_key_records_a_secret_as_held_back_and_writes_nothing()
    {
        Stager stager = NewStager(key: false);

        StagedEntry entry = stager.WriteText(temp["staging", "token.txt"], "token " + Fake.GitHubToken());

        entry.As.Should().Be(StagedAs.HeldBack);
        entry.Stored.Should().BeNull();
        Directory.Exists(temp["staging"]).Should().BeFalse();
    }

    [Fact]
    public void Can_hold_a_secret_back_even_with_a_key()
    {
        StagedEntry entry = NewStager().WriteText(temp["staging", "repos.json"], "token " + Fake.GitHubToken(), seal: false);

        entry.As.Should().Be(StagedAs.HeldBack);
        Directory.Exists(temp["staging"]).Should().BeFalse();
    }

    [Fact]
    public void The_last_check_leaves_a_file_the_review_called_no_secret_as_it_is()
    {
        string source = temp.Write("appsettings.json", "{ \"ClientSecret\": \"Zx9Qw3Er7Ty1Ui5Op2As8Df4\" }");
        Stager stager = NewStager();

        StagedEntry entry = stager.CopyFile(source, temp["staging", "appsettings.json"], accepted: ["SecretValue:ClientSecret"]);
        IReadOnlyList<StagedEntry> rest = stager.CheckRest();

        entry.As.Should().Be(StagedAs.Plain);
        rest.Should().BeEmpty();
        File.Exists(temp["staging", "appsettings.json"]).Should().BeTrue();
        File.Exists(temp["staging", "appsettings.json.age"]).Should().BeFalse();
    }

    [Fact]
    public void The_last_check_encrypts_what_came_in_another_way()
    {
        Stager stager = NewStager();
        stager.WriteText(temp["staging", "clean.txt"], "clean");
        temp.Write(Path.Combine("staging", "direct.txt"), "token " + Fake.GitHubToken());

        IReadOnlyList<StagedEntry> rest = stager.CheckRest();

        rest.Should().ContainSingle().Which.Should().Match<StagedEntry>(e => e.Path == "direct.txt" && e.As == StagedAs.Sealed);
        File.Exists(temp["staging", "direct.txt"]).Should().BeFalse();
        stager.Find("direct.txt")!.Stored.Should().Be("direct.txt.age");
    }

    [Fact]
    public void Copies_an_age_file_as_it_is()
    {
        byte[] encrypted = Age.Encrypt(Encoding.UTF8.GetBytes("x"), Key.Recipient);
        string source = temp["published.age"];
        File.WriteAllBytes(source, encrypted);

        StagedEntry entry = NewStager().CopyFile(source, temp["staging", "kept", "published.age"]);

        entry.Should().Match<StagedEntry>(e => e.As == StagedAs.Plain && e.Stored == "kept/published.age");
        File.ReadAllBytes(temp["staging", "kept", "published.age"]).Should().Equal(encrypted);
    }

    [Fact]
    public void Scans_utf16_text_without_a_byte_order_mark()
    {
        string text = "token " + Fake.GitHubToken();
        string little = temp["utf16le.txt"];
        string big = temp["utf16be.txt"];
        File.WriteAllBytes(little, Encoding.Unicode.GetBytes(text));
        File.WriteAllBytes(big, Encoding.BigEndianUnicode.GetBytes(text));

        SecretScanner.ScanFile(little).Should().Match<FileScan>(s => !s.IsBinary && s.HasSecret);
        SecretScanner.ScanFile(big).Should().Match<FileScan>(s => !s.IsBinary && s.HasSecret);
    }

    [Fact]
    public void Binary_with_nul_bytes_stays_binary()
    {
        string path = temp["data.bin"];
        File.WriteAllBytes(path, [0x00, 0x01, 0x02, 0x00, 0x7F, 0x00, 0xFF, 0x10, 0x00, 0x00]);

        SecretScanner.ScanFile(path).IsBinary.Should().BeTrue();
    }

    [Theory]
    [InlineData("out.txt")]
    [InlineData("staging")]
    public void Refuses_a_path_outside_the_staging_folder(params string[] parts)
    {
        Stager stager = NewStager();

        FluentActions.Invoking(() => stager.WriteText(temp[parts], "x")).Should().Throw<ArgumentException>();
    }
}
