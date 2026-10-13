using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class StagingWriterTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    [Fact]
    public void Writes_a_text_without_a_secret()
    {
        string path = temp["staging", "settings.json"];

        FileScan scan = StagingWriter.WriteText(path, "{ \"theme\": \"dark\" }");

        scan.HasSecret.Should().BeFalse();
        File.ReadAllText(path).Should().Be("{ \"theme\": \"dark\" }");
    }

    [Fact]
    public void Writes_nothing_of_a_text_with_a_secret_and_says_where_it_is()
    {
        string path = temp["staging", "settings.json"];

        FileScan scan = StagingWriter.WriteText(path, "{\n  \"token\": \"" + Fake.GitHubToken() + "\"\n}");

        scan.Findings.Should().ContainSingle().Which.Should().Match<SecretFinding>(f => f.Kind == SecretKind.GitHubToken && f.Line == 2);
        // Not the file, and no temporary file either: the secret never reached the disk.
        Directory.GetFiles(temp.Path, "*", SearchOption.AllDirectories).Should().BeEmpty();
    }

    [Fact]
    public void Copies_a_file_without_a_secret_byte_for_byte()
    {
        string source = temp["home", "profile.ps1"];
        Directory.CreateDirectory(temp["home"]);
        byte[] bytes = [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes("Set-PSReadLineOption -EditMode Emacs\r\n")];
        File.WriteAllBytes(source, bytes);
        string path = temp["staging", "pwsh", "profile.ps1"];

        StagingWriter.CopyFile(source, path).HasSecret.Should().BeFalse();

        File.ReadAllBytes(path).Should().Equal(bytes);
    }

    [Fact]
    public void Copies_nothing_of_a_file_with_a_secret()
    {
        string source = temp.Write("home/profile.ps1", "\n\n$env:GITHUB_TOKEN = '" + Fake.GitHubToken() + "'\n");
        string path = temp["staging", "pwsh", "profile.ps1"];

        FileScan scan = StagingWriter.CopyFile(source, path);

        scan.Findings.Should().ContainSingle().Which.Line.Should().Be(3);
        File.Exists(path).Should().BeFalse();
    }

    [Fact]
    public void Copies_a_binary_file_unscanned()
    {
        string source = temp["home", "logo.png"];
        Directory.CreateDirectory(temp["home"]);
        byte[] bytes = [0x89, (byte)'P', (byte)'N', (byte)'G', 0, .. Encoding.ASCII.GetBytes(Fake.GitHubToken())];
        File.WriteAllBytes(source, bytes);
        string path = temp["staging", "logo.png"];

        FileScan scan = StagingWriter.CopyFile(source, path);

        scan.IsBinary.Should().BeTrue();
        File.ReadAllBytes(path).Should().Equal(bytes);
    }

    [Fact]
    public void Refuses_relative_paths()
    {
        ((Action)(() => StagingWriter.WriteText("settings.json", "x"))).Should().Throw<ArgumentException>();
        ((Action)(() => StagingWriter.CopyFile("a.txt", temp["b.txt"]))).Should().Throw<ArgumentException>();
    }
}
