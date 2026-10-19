using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class RestorePlannerTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private string Snapshot => temp["snapshot"];

    private string Repo => temp["repo"];

    /// <summary>A repository to restore into, and one file in the snapshot stored as <paramref name="stored"/>.</summary>
    private ManifestFile Backed(string path, string content, string? stored = null)
    {
        Directory.CreateDirectory(Path.Combine(Repo, ".git"));
        temp.Write(Path.Combine("snapshot", stored ?? path), content);
        return new ManifestFile(path, stored ?? path);
    }

    private RestoreResult Restore(ManifestFile file, RestoreScope scope = RestoreScope.Repository, string prefix = "", string? identity = null, bool dryRun = false) =>
        RestorePlanner.Restore(Snapshot, file, scope == RestoreScope.Repository ? Repo : temp["claude"], prefix, scope, identity, dryRun);

    [Fact]
    public void Writes_a_missing_file_and_leaves_one_that_is_there()
    {
        ManifestFile file = Backed("config/.env", "A=1");

        Restore(file).Outcome.Should().Be(RestoreOutcome.Restored);
        File.ReadAllText(Path.Combine(Repo, "config", ".env")).Should().Be("A=1");
        Restore(file).Outcome.Should().Be(RestoreOutcome.Present);
        File.WriteAllText(Path.Combine(Repo, "config", ".env"), "A=2");
        Restore(file).Outcome.Should().Be(RestoreOutcome.Differs);
        File.ReadAllText(Path.Combine(Repo, "config", ".env")).Should().Be("A=2");
        Directory.GetFiles(Path.Combine(Repo, "config")).Should().HaveCount(1, "no temporary file is left behind");
    }

    [Fact]
    public void Decrypts_a_secret_and_skips_it_without_a_key()
    {
        AgeKey key = Age.NewKey();
        Directory.CreateDirectory(Path.Combine(Repo, ".git"));
        Directory.CreateDirectory(Snapshot);
        File.WriteAllBytes(Path.Combine(Snapshot, ".env.age"), Age.Encrypt(Encoding.UTF8.GetBytes("TOKEN=x"), key.Recipient));
        ManifestFile file = new(".env", ".env.age");

        Restore(file).Outcome.Should().Be(RestoreOutcome.Skipped);
        File.Exists(Path.Combine(Repo, ".env")).Should().BeFalse();
        Restore(file, identity: key.Identity).Outcome.Should().Be(RestoreOutcome.Restored);
        File.ReadAllText(Path.Combine(Repo, ".env")).Should().Be("TOKEN=x");
    }

    [Fact]
    public void Writes_nothing_in_a_dry_run()
    {
        ManifestFile file = Backed("deep/er/.env", "A=1");

        Restore(file, dryRun: true).Outcome.Should().Be(RestoreOutcome.Restored);
        Directory.Exists(Path.Combine(Repo, "deep")).Should().BeFalse();
    }

    [Theory]
    [InlineData(".git/hooks/post-checkout")]
    [InlineData("sub/.GIT/config")]
    [InlineData("../outside.txt")]
    [InlineData("a/../../outside.txt")]
    [InlineData("/etc/passwd")]
    [InlineData("a//b")]
    [InlineData("./a")]
    [InlineData("a\\b")]
    [InlineData("")]
    public void Refuses_a_path_that_is_not_plain_or_leads_into_git(string path)
    {
        RestorePlanner.Refusal(path, RestoreScope.Repository).Should().NotBeNull();
    }

    [Theory]
    [InlineData(".git./hooks/x")]
    [InlineData(".git /hooks/x")]
    [InlineData("GIT~1/hooks/x")]
    [InlineData(".env:stream")]
    [InlineData("C:/Windows/x")]
    [InlineData("nul.txt")]
    [InlineData("sub/COM1")]
    [InlineData("name.")]
    public void Refuses_what_Windows_reads_as_another_name(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Skip("Windows names");
        }
        RestorePlanner.Refusal(path, RestoreScope.Repository).Should().NotBeNull();
    }

    [Theory]
    [InlineData(".env")]
    [InlineData("src/appsettings.Development.json")]
    [InlineData(".claude/settings.local.json")]
    [InlineData("bin/app.config")]
    public void Allows_a_plain_path_in_a_repository(string path)
    {
        RestorePlanner.Refusal(path, RestoreScope.Repository).Should().BeNull();
    }

    [Fact]
    public void Refuses_a_manifest_path_into_git_before_reading_anything()
    {
        ManifestFile file = Backed(".git/hooks/post-checkout", "#!/bin/sh");

        FluentActions.Invoking(() => Restore(file)).Should().Throw<InvalidDataException>().WithMessage("*.git*refused*");
        File.Exists(Path.Combine(Repo, ".git", "hooks", "post-checkout")).Should().BeFalse();
    }

    [Fact]
    public void Refuses_a_stored_name_that_is_not_the_path()
    {
        ManifestFile file = Backed(".env", "A=1", stored: "other.txt");

        FluentActions.Invoking(() => Restore(file)).Should().Throw<InvalidDataException>().WithMessage("*stored as other.txt*");
    }

    [Fact]
    public void Refuses_a_stored_name_out_of_the_snapshot()
    {
        Directory.CreateDirectory(Path.Combine(Repo, ".git"));
        temp.Write("elsewhere.txt.age", "x");

        FluentActions.Invoking(() => Restore(new ManifestFile("../elsewhere.txt", "../elsewhere.txt.age"))).Should().Throw<InvalidDataException>();
    }

    [Fact]
    public void Refuses_a_nested_repository()
    {
        ManifestFile file = Backed("vendor/lib/.env", "A=1");
        Directory.CreateDirectory(Path.Combine(Repo, "vendor", "lib", ".git"));

        FluentActions.Invoking(() => Restore(file)).Should().Throw<InvalidDataException>().WithMessage("*repository of its own*");
        File.Exists(Path.Combine(Repo, "vendor", "lib", ".env")).Should().BeFalse();
    }

    [Fact]
    public void Refuses_a_link_on_the_way_and_as_the_file()
    {
        ManifestFile inLink = Backed("linked/.env", "A=1");
        ManifestFile asLink = Backed("file.env", "A=1");
        string outside = temp.Write("outside/file.env", "B=2");
        try
        {
            Directory.CreateSymbolicLink(Path.Combine(Repo, "linked"), Path.GetDirectoryName(outside)!);
            File.CreateSymbolicLink(Path.Combine(Repo, "file.env"), outside);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Assert.Skip("this account cannot create symbolic links");
        }

        FluentActions.Invoking(() => Restore(inLink)).Should().Throw<InvalidDataException>().WithMessage("*is a link*");
        FluentActions.Invoking(() => Restore(asLink)).Should().Throw<InvalidDataException>().WithMessage("*is a link*");
        File.Exists(Path.Combine(Path.GetDirectoryName(outside)!, ".env")).Should().BeFalse();
        File.ReadAllText(outside).Should().Be("B=2");
    }

    [Fact]
    public void Says_when_the_snapshot_lacks_the_file()
    {
        Directory.CreateDirectory(Path.Combine(Repo, ".git"));
        Directory.CreateDirectory(Snapshot);

        FluentActions.Invoking(() => Restore(new ManifestFile(".env", ".env"))).Should().Throw<InvalidDataException>().WithMessage("*missing from the snapshot*");
    }

    [Theory]
    [InlineData("settings.json", true)]
    [InlineData("CLAUDE.md", true)]
    [InlineData("statusline.ps1", true)]
    [InlineData("skills/ship/SKILL.md", true)]
    [InlineData("commands/ship.md", true)]
    [InlineData(".credentials.json", false)]
    [InlineData("history.jsonl", false)]
    [InlineData("projects/C--x/memory/a.md", false)]
    [InlineData("skills/ship/node_modules/x.js", false)]
    [InlineData("skills", false)]
    public void Allows_only_the_selection_in_Claude_Codes_folder(string path, bool allowed)
    {
        (RestorePlanner.Refusal(path, RestoreScope.ClaudeHome) is null).Should().Be(allowed);
    }

    [Theory]
    [InlineData("projects/C--Repos-App/memory/MEMORY.md", true)]
    [InlineData("projects/C--Repos-App/memory/deep/note.md", true)]
    [InlineData("projects/C--Repos-App/session.jsonl", true)]
    [InlineData("projects/C--Repos-App/settings.json", false)]
    [InlineData("projects/C:Repos/memory/x.md", false)]
    [InlineData("projects/C--Repos-App/memory", false)]
    [InlineData("settings.json", false)]
    public void Allows_only_memory_and_transcripts_in_a_project(string path, bool allowed)
    {
        (RestorePlanner.Refusal(path, RestoreScope.ClaudeProject) is null).Should().Be(allowed);
    }

    [Fact]
    public void Creates_Claude_Codes_folder_for_a_project()
    {
        temp.Write("snapshot/memory/MEMORY.md", "remember");

        RestoreResult result = Restore(new ManifestFile("memory/MEMORY.md", "memory/MEMORY.md"), RestoreScope.ClaudeProject, "projects/C--Repos-App");

        result.Outcome.Should().Be(RestoreOutcome.Restored);
        File.ReadAllText(temp["claude", "projects", "C--Repos-App", "memory", "MEMORY.md"]).Should().Be("remember");
    }

    [Fact]
    public void Resolves_a_path_below_a_folder()
    {
        string root = temp["Repos"];

        RestorePlanner.Below(root, ".").Should().Be(root);
        RestorePlanner.Below(root, "Org/App").Should().Be(Path.Combine(root, "Org", "App"));
        FluentActions.Invoking(() => RestorePlanner.Below(root, "../Other")).Should().Throw<InvalidDataException>();
        FluentActions.Invoking(() => RestorePlanner.Below(root, "App/.git")).Should().Throw<InvalidDataException>();
    }
}

public sealed class RestoreManifestTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    [Fact]
    public void Reads_files_json()
    {
        string file = temp.Write("files.json", """
            { "format": 1, "repositories": [
              { "identity": "github.com/o/app", "root": "C:\\Repos", "path": "App", "folder": "github.com/o/app",
                "files": [ { "path": ".env", "stored": ".env.age" }, { "path": "a.json", "stored": "a.json" } ] } ] }
            """);

        RepoFilesManifest manifest = RestoreManifest.ReadRepoFiles(file);

        manifest.Repositories.Should().ContainSingle();
        RepoFilesEntry entry = manifest.Repositories[0];
        entry.Identity.Should().Be("github.com/o/app");
        entry.Files.Select(f => f.Encrypted).Should().Equal(true, false);
    }

    [Fact]
    public void Reads_claude_files_json()
    {
        string file = temp.Write("claude-files.json", """
            { "format": 1, "home": [ { "path": "settings.json", "stored": "settings.json" } ],
              "projects": [
                { "name": "C--Repos-App", "identity": "github.com/o/app", "root": "C:\\Repos", "path": "App", "folder": "github.com/o/app",
                  "files": [ { "path": "memory/MEMORY.md", "stored": "memory/MEMORY.md" } ] },
                { "name": "C--Other", "folder": "path/C--Other", "files": [ { "path": "memory/a.md", "stored": "memory/a.md" } ] } ],
              "claudeJson": "claude.json.age" }
            """);

        ClaudeManifest manifest = RestoreManifest.ReadClaude(file);

        manifest.Home.Should().ContainSingle();
        manifest.Projects.Select(p => p.Identity).Should().Equal("github.com/o/app", null);
        manifest.ClaudeJson.Should().Be("claude.json.age");
    }

    [Theory]
    [InlineData("""{ "format": 2, "repositories": [] }""", "*newer PSPhoenix*")]
    [InlineData("""{ "repositories": [] }""", "*no format*")]
    [InlineData("""[]""", "*not a PSPhoenix manifest*")]
    [InlineData("""{ "format": 1, "repositories": {} }""", "*repositories is not a list*")]
    [InlineData("""{ "format": 1, "repositories": [ { "identity": "x", "root": "r", "path": 3, "folder": "f" } ] }""", "*repositories?0?.path is not a text*")]
    [InlineData("""{ "format": 1, "repositories": [ { "identity": "x", "root": "r", "path": "p" } ] }""", "*has no folder*")]
    [InlineData("""{ "format": 1, "repositories": [ { "identity": "x", "root": "r", "path": "p", "folder": "f", "files": [ "a" ] } ] }""", "*files?0? is not an object*")]
    [InlineData("""{ "format": 1, """, "*not valid JSON*")]
    public void Refuses_a_manifest_that_is_not_what_PSPhoenix_writes(string json, string message)
    {
        string file = temp.Write("files.json", json);

        FluentActions.Invoking(() => RestoreManifest.ReadRepoFiles(file)).Should().Throw<InvalidDataException>().WithMessage(message);
    }
}
