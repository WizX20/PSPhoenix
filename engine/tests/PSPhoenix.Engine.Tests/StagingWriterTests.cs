using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class StagingWriterTests : IDisposable
{
    private static readonly AgeKey Key = Age.NewKey();
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private Sealer NewSealer(string? recipient = null) => new(recipient ?? Key.Recipient, temp["state", "sealed"]);

    [Fact]
    public void Writes_a_text_without_a_secret()
    {
        string path = temp["staging", "settings.json"];

        StagedFile staged = StagingWriter.WriteText(path, "{ \"theme\": \"dark\" }", NewSealer());

        staged.Should().Match<StagedFile>(s => !s.Scan.HasSecret && !s.Sealed && !s.HeldBack);
        File.ReadAllText(path).Should().Be("{ \"theme\": \"dark\" }");
    }

    [Fact]
    public void Without_a_sealer_writes_nothing_of_a_text_with_a_secret_and_says_where_it_is()
    {
        string path = temp["staging", "settings.json"];

        StagedFile staged = StagingWriter.WriteText(path, "{\n  \"token\": \"" + Fake.GitHubToken() + "\"\n}");

        staged.HeldBack.Should().BeTrue();
        staged.Scan.Findings.Should().ContainSingle().Which.Should().Match<SecretFinding>(f => f.Kind == SecretKind.GitHubToken && f.Line == 2);
        // Not the file, and no temporary file either: the secret never reached the disk.
        Directory.GetFiles(temp.Path, "*", SearchOption.AllDirectories).Should().BeEmpty();
    }

    [Fact]
    public void With_a_sealer_writes_a_text_with_a_secret_encrypted_and_nothing_in_plain()
    {
        string path = temp["staging", "settings.json"];
        string text = "{ \"token\": \"" + Fake.GitHubToken() + "\" }";

        StagedFile staged = StagingWriter.WriteText(path, text, NewSealer());

        staged.Sealed.Should().BeTrue();
        staged.HeldBack.Should().BeFalse();
        File.Exists(path).Should().BeFalse();
        Age.Decrypt(File.ReadAllBytes(path + ".age"), Key.Identity).Should().Equal(Encoding.UTF8.GetBytes(text));
        Directory.GetFiles(temp["staging"]).Should().Equal(path + ".age");
    }

    [Fact]
    public void An_unchanged_secret_gets_the_same_ciphertext_and_a_changed_one_a_new_one()
    {
        string path = temp["staging", "settings.json"];
        string text = "Password=" + "Winter2024!";
        StagingWriter.WriteText(path, text, NewSealer());
        byte[] first = File.ReadAllBytes(path + ".age");
        File.Delete(path + ".age");

        StagingWriter.WriteText(path, text, NewSealer());
        File.ReadAllBytes(path + ".age").Should().Equal(first, "a sync client must not upload a secret that did not change");

        StagingWriter.WriteText(path, "Password=" + "Summer2025!", NewSealer());
        File.ReadAllBytes(path + ".age").Should().NotEqual(first);
        Age.Decrypt(File.ReadAllBytes(path + ".age"), Key.Identity).Should().Equal(Encoding.UTF8.GetBytes("Password=" + "Summer2025!"));
    }

    [Fact]
    public void A_cached_ciphertext_the_stamp_does_not_vouch_for_is_not_used()
    {
        // A run died between writing a new ciphertext (for another plaintext) and its stamp; the
        // plaintext then went back to what the stamp names.
        string path = temp["staging", "db.txt"];
        StagingWriter.WriteText(path, "Password=" + "Winter2024!", NewSealer());
        string cached = Directory.GetFiles(temp["state", "sealed"], "*.age").Single();
        File.WriteAllBytes(cached, Age.Encrypt(Encoding.UTF8.GetBytes("Password=" + "Summer2025!"), Key.Recipient));

        StagingWriter.WriteText(path, "Password=" + "Winter2024!", NewSealer());

        Age.Decrypt(File.ReadAllBytes(path + ".age"), Key.Identity).Should().Equal(Encoding.UTF8.GetBytes("Password=" + "Winter2024!"));
    }

    [Fact]
    public void A_text_that_only_starts_like_an_age_file_is_scanned()
    {
        string path = temp.Write("staging/fake.age", "age-encryption.org/v1\ntoken " + Fake.GitHubToken() + "\n");

        StagingWriter.CheckStaged(path).HeldBack.Should().BeTrue();
        File.Exists(path).Should().BeFalse();
    }

    [Fact]
    public void Another_recipient_gets_a_new_ciphertext()
    {
        string path = temp["staging", "db.txt"];
        StagingWriter.WriteText(path, "Password=" + "Winter2024!", NewSealer());
        AgeKey other = Age.NewKey();

        StagingWriter.WriteText(path, "Password=" + "Winter2024!", NewSealer(other.Recipient));

        Age.Decrypt(File.ReadAllBytes(path + ".age"), other.Identity).Should().Equal(Encoding.UTF8.GetBytes("Password=" + "Winter2024!"));
    }

    [Fact]
    public void Copies_a_file_without_a_secret_byte_for_byte()
    {
        string source = temp["home", "profile.ps1"];
        Directory.CreateDirectory(temp["home"]);
        byte[] bytes = [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes("Set-PSReadLineOption -EditMode Emacs\r\n")];
        File.WriteAllBytes(source, bytes);
        string path = temp["staging", "pwsh", "profile.ps1"];

        StagingWriter.CopyFile(source, path).Scan.HasSecret.Should().BeFalse();

        File.ReadAllBytes(path).Should().Equal(bytes);
    }

    [Fact]
    public void Copies_a_file_with_a_secret_encrypted_byte_for_byte_or_not_at_all()
    {
        string source = temp.Write("home/profile.ps1", "\n\n$env:GITHUB_TOKEN = '" + Fake.GitHubToken() + "'\n");
        string path = temp["staging", "pwsh", "profile.ps1"];

        StagedFile held = StagingWriter.CopyFile(source, path);
        held.HeldBack.Should().BeTrue();
        held.Scan.Findings.Should().ContainSingle().Which.Line.Should().Be(3);
        Directory.Exists(temp["staging"]).Should().BeFalse();

        StagingWriter.CopyFile(source, path, NewSealer()).Sealed.Should().BeTrue();
        Age.Decrypt(File.ReadAllBytes(path + ".age"), Key.Identity).Should().Equal(File.ReadAllBytes(source));
    }

    [Fact]
    public void Copies_a_binary_file_unscanned()
    {
        string source = temp["home", "logo.png"];
        Directory.CreateDirectory(temp["home"]);
        byte[] bytes = [0x89, (byte)'P', (byte)'N', (byte)'G', 0, .. Encoding.ASCII.GetBytes(Fake.GitHubToken())];
        File.WriteAllBytes(source, bytes);
        string path = temp["staging", "logo.png"];

        StagedFile staged = StagingWriter.CopyFile(source, path, NewSealer());

        staged.Scan.IsBinary.Should().BeTrue();
        File.ReadAllBytes(path).Should().Equal(bytes);
    }

    [Fact]
    public void Checks_a_file_already_staged_encrypting_or_removing_a_secret()
    {
        string clean = temp.Write("staging/clean.txt", "nothing");
        string leaked = temp.Write("staging/leaked.txt", "token " + Fake.GitLabToken());
        string held = temp.Write("staging/held.txt", "token " + Fake.GitLabToken());

        StagingWriter.CheckStaged(clean, NewSealer()).Scan.HasSecret.Should().BeFalse();
        StagingWriter.CheckStaged(leaked, NewSealer()).Sealed.Should().BeTrue();
        StagingWriter.CheckStaged(held).HeldBack.Should().BeTrue();

        Directory.GetFiles(temp["staging"]).Select(Path.GetFileName).Order(StringComparer.Ordinal).Should().Equal("clean.txt", "leaked.txt.age");
        // An age file is encrypted already: the check leaves it alone.
        StagingWriter.CheckStaged(leaked + ".age").Scan.IsBinary.Should().BeTrue();
    }

    [Fact]
    public void Refuses_relative_paths_and_a_sealer_without_a_recipient()
    {
        ((Action)(() => StagingWriter.WriteText("settings.json", "x"))).Should().Throw<ArgumentException>();
        ((Action)(() => StagingWriter.CopyFile("a.txt", temp["b.txt"]))).Should().Throw<ArgumentException>();
        ((Func<Sealer>)(() => new Sealer("age1nope", temp["state"]))).Should().Throw<ArgumentException>();
        ((Func<Sealer>)(() => new Sealer(Key.Recipient, "state"))).Should().Throw<ArgumentException>();
    }
}
