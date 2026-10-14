using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class PathPatternTests
{
    [Theory]
    [InlineData("config.local.env", "config.local.env", true)]
    [InlineData("config.local.env", "sub/config.local.env", true)]
    [InlineData("config.local.env", "config.local.env.bak", false)]
    [InlineData("*.local.json", "src/App/appsettings.local.json", true)]
    [InlineData("*.local.json", "src/App/appsettings.json", false)]
    [InlineData("docker/services.local.env", "docker/services.local.env", true)]
    [InlineData("docker/services.local.env", "x/docker/services.local.env", false)]
    [InlineData("**/appsettings*.local.json", "appsettings.Development.local.json", true)]
    [InlineData("**/appsettings*.local.json", "src/a/b/appsettings.local.json", true)]
    [InlineData("docs/", "docs/notes/a.md", true)]
    [InlineData("docs/", "docs", false)]
    [InlineData("docs/", "src/docs/a.md", true)]
    [InlineData("src/docs/", "docs/a.md", false)]
    [InlineData("notes", "notes/a.md", true)]
    [InlineData("src/**/local.json", "src/local.json", true)]
    [InlineData("src/**/local.json", "src/a/b/local.json", true)]
    [InlineData("src/**", "src/a/b.txt", true)]
    [InlineData("?.txt", "a.txt", true)]
    [InlineData("?.txt", "ab.txt", false)]
    [InlineData("*.TXT", "Notes.txt", true)]
    [InlineData("./config.env", "config.env", true)]
    [InlineData("/config.env", "config.env", true)]
    [InlineData("a+b(1).txt", "a+b(1).txt", true)]
    public void Matches_like_a_gitignore_pattern(string pattern, string path, bool expected)
    {
        PathPattern.Parse(pattern).IsMatch(path).Should().Be(expected);
    }

    [Fact]
    public void Takes_backslashes_as_separators()
    {
        PathPattern.Parse(@"docker\services.env").IsMatch(@"docker\services.env").Should().BeTrue();
    }

    [Theory]
    [InlineData("")]
    [InlineData("/")]
    [InlineData("../x")]
    [InlineData("a/../b")]
    [InlineData("a//b")]
    public void Refuses_a_pattern_that_is_no_path_inside_the_repository(string pattern)
    {
        PathPattern.TryParse(pattern, out _, out string? error).Should().BeFalse();
        error.Should().NotBeNullOrEmpty();
        FluentActions.Invoking(() => PathPattern.Parse(pattern)).Should().Throw<ArgumentException>();
    }
}

public sealed class IgnoredFilesTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private IgnoredFileList List(params string[] entries) => IgnoredFiles.List(temp.Path, entries, 1024);

    [Fact]
    public void Lists_files_and_walks_folders()
    {
        temp.Write("config.local.env", "a=1");
        temp.Write("notes/todo.md", "x");
        temp.Write("notes/deep/more.md", "y");

        IgnoredFileList list = List("config.local.env", "notes/");

        list.Files.Select(f => f.Path).Should().Equal("config.local.env", "notes/deep/more.md", "notes/todo.md");
        list.Files.Should().OnlyContain(f => f.Filter == CandidateFilter.None && !f.SecretName);
        list.Files[0].Size.Should().Be(3);
        list.Truncated.Should().BeFalse();
    }

    [Fact]
    public void Never_enters_a_denied_folder_at_any_depth()
    {
        temp.Write("leftover/keep.txt", "x");
        temp.Write("leftover/src/App/bin/Debug/App.dll", "x");
        temp.Write("leftover/src/App/obj/project.assets.json", "x");
        temp.Write("leftover/web/node_modules/x/index.js", "x");
        temp.Write("leftover/.claude/worktrees/feature/notes.md", "x");
        temp.Write("leftover/.claude/settings.local.json", "{}");

        IgnoredFileList list = List("leftover/", "bin/", "obj/Debug/x.txt");

        list.Files.Select(f => f.Path).Should().Equal("leftover/.claude/settings.local.json", "leftover/keep.txt");
    }

    [Fact]
    public void Denies_a_segment_ignoring_case()
    {
        IgnoredFiles.IsDenied("src/Bin/x.txt").Should().BeTrue();
        IgnoredFiles.IsDenied("src/NODE_MODULES").Should().BeTrue();
        IgnoredFiles.IsDenied("a/.Claude/Worktrees/b").Should().BeTrue();
        IgnoredFiles.IsDenied("src/binary/x.txt").Should().BeFalse();
        IgnoredFiles.IsDenied(".claude/worktrees-notes.md").Should().BeFalse();
    }

    [Fact]
    public void Does_not_enter_a_repository_or_a_virtual_environment_of_its_own()
    {
        temp.Write("vendor/lib/.git/HEAD", "ref: refs/heads/main");
        temp.Write("vendor/lib/tracked.txt", "x");
        temp.Write("worktree/.git", "gitdir: elsewhere");
        temp.Write("worktree/file.txt", "x");
        temp.Write(".env/pyvenv.cfg", "home = /usr/bin");
        temp.Write(".env/lib/site.py", "x");
        temp.Write("vendor/readme.md", "x");

        IgnoredFileList list = List("vendor/", "worktree/", ".env/");

        list.Files.Select(f => f.Path).Should().Equal("vendor/readme.md");
    }

    [Fact]
    public void Marks_generated_noise_binary_and_large_files()
    {
        temp.Write("lib/model.g.dart", "x");
        temp.Write("package-lock.json", "{}");
        temp.Write("debug.log", "x");
        temp.Write("logo.PNG", "x");
        temp.Write("dump.json", new string('x', 2000));
        temp.Write("ok.json", "{}");

        Dictionary<string, CandidateFilter> filters = List("lib/model.g.dart", "package-lock.json", "debug.log", "logo.PNG", "dump.json", "ok.json")
            .Files.ToDictionary(f => f.Path, f => f.Filter);

        filters.Should().BeEquivalentTo(new Dictionary<string, CandidateFilter>
        {
            ["lib/model.g.dart"] = CandidateFilter.Generated,
            ["package-lock.json"] = CandidateFilter.Generated,
            ["debug.log"] = CandidateFilter.Noise,
            ["logo.PNG"] = CandidateFilter.Binary,
            ["dump.json"] = CandidateFilter.Large,
            ["ok.json"] = CandidateFilter.None,
        });
    }

    [Fact]
    public void Classifies_secrets_by_name_and_by_the_repository_s_own_patterns()
    {
        foreach (string name in new[] { ".env", ".env.local", "secrets.json", "cert.pfx", "server.pem", "api.key", "id_ed25519", "deploy.conf", "plain.txt" })
        {
            temp.Write("keys/" + name, "x");
        }

        IgnoredFileList list = IgnoredFiles.List(temp.Path, ["keys/"], 1024, ["deploy.*"]);

        list.Files.Where(f => !f.SecretName).Select(f => f.Path).Should().Equal("keys/plain.txt");
        // A binary extension that is a secret is not filtered as binary: it is a candidate.
        list.Files.Single(f => f.Path == "keys/cert.pfx").Filter.Should().Be(CandidateFilter.None);
    }

    [Fact]
    public void A_folder_named_like_a_secret_file_does_not_make_its_files_secret()
    {
        temp.Write("secrets.d/readme.md", "x");

        List("secrets.d/").Files.Should().ContainSingle().Which.SecretName.Should().BeFalse();
    }

    [Fact]
    public void Skips_entries_that_are_gone_or_lead_out_of_the_repository()
    {
        temp.Write("here.txt", "x");

        List("gone.txt", "gone/", "../outside.txt", "here.txt").Files.Select(f => f.Path).Should().Equal("here.txt");
    }

    [Fact]
    public void Stops_at_the_most_files_a_walk_looks_at()
    {
        string folder = temp["many"];
        Directory.CreateDirectory(folder);
        for (int i = 0; i <= IgnoredFiles.MaxFiles; i++)
        {
            File.WriteAllBytes(Path.Combine(folder, $"f{i}.txt"), []);
        }

        IgnoredFileList list = List("many/");

        list.Truncated.Should().BeTrue();
        list.Files.Should().HaveCount(IgnoredFiles.MaxFiles);
    }

    [Fact]
    public void Does_not_follow_a_link()
    {
        string outside = temp.Write("outside/secret.txt", "x");
        temp.Write("repo/real.txt", "x");
        string repo = temp["repo"];
        try
        {
            Directory.CreateSymbolicLink(Path.Combine(repo, "linked"), Path.GetDirectoryName(outside)!);
            File.CreateSymbolicLink(Path.Combine(repo, "file-link.txt"), outside);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Assert.Skip("this account cannot create symbolic links");
        }

        IgnoredFiles.List(repo, ["linked/", "file-link.txt", "real.txt"], 1024).Files.Select(f => f.Path).Should().Equal("real.txt");
    }
}

public sealed class FileRulesTests
{
    private static IgnoredFile File(string path, bool secretName = false, CandidateFilter filter = CandidateFilter.None) => new(path, 1, secretName, filter);

    [Fact]
    public void Leaves_a_candidate_nobody_decided_on_pending()
    {
        new FileRules().Decide(File("notes.md")).Should().Be(FileDecision.Pending);
    }

    [Fact]
    public void A_built_in_filter_excludes_unless_the_review_includes()
    {
        FileRules rules = new(include: ["big.json"]);

        rules.Decide(File("big.json", filter: CandidateFilter.Large)).Should().Be(FileDecision.Include);
        rules.Decide(File("other.json", filter: CandidateFilter.Large)).Should().Be(FileDecision.Exclude);
    }

    [Fact]
    public void Secret_beats_include_beats_exclude()
    {
        FileRules rules = new(include: ["config/keep.env", "config/both.env"], secret: ["config/both.env", "**/*.secret"], exclude: ["config/"]);

        rules.Decide(File("config/keep.env")).Should().Be(FileDecision.Include);
        rules.Decide(File("config/both.env")).Should().Be(FileDecision.Secret);
        rules.Decide(File("config/other.env")).Should().Be(FileDecision.Exclude);
        rules.Decide(File("config/x.secret")).Should().Be(FileDecision.Secret);
    }

    [Fact]
    public void An_included_file_with_a_secret_name_is_secret()
    {
        new FileRules(include: [".env"]).Decide(File(".env", secretName: true)).Should().Be(FileDecision.Secret);
    }

    [Fact]
    public void Refuses_a_pattern_that_is_not_one()
    {
        FluentActions.Invoking(() => new FileRules(exclude: ["../x"])).Should().Throw<ArgumentException>();
    }
}

public sealed class SecretCopyTests : IDisposable
{
    private static readonly AgeKey Key = Age.NewKey();
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    [Fact]
    public void A_secret_file_is_only_staged_encrypted_even_when_binary_or_clean()
    {
        string binary = temp["cert.pfx"];
        System.IO.File.WriteAllBytes(binary, [0x30, 0x82, 0x00, 0x01, 0x02]);
        string clean = temp.Write(".env", "LOG_LEVEL=debug");
        Sealer sealer = new(Key.Recipient, temp["sealed"]);

        StagedFile pfx = StagingWriter.CopyFile(binary, temp["staging", "cert.pfx"], sealer, secret: true);
        StagedFile env = StagingWriter.CopyFile(clean, temp["staging", ".env"], sealer, secret: true);

        pfx.Sealed.Should().BeTrue();
        env.Sealed.Should().BeTrue();
        env.Scan.Findings.Should().ContainSingle().Which.Kind.Should().Be(SecretKind.SecretFile);
        Directory.GetFiles(temp["staging"]).Select(Path.GetFileName).Should().BeEquivalentTo("cert.pfx.age", ".env.age");
        Age.Decrypt(System.IO.File.ReadAllBytes(temp["staging", ".env.age"]), Key.Identity).Should().Equal(Encoding.UTF8.GetBytes("LOG_LEVEL=debug"));
    }

    [Fact]
    public void Without_a_key_a_secret_file_is_held_back()
    {
        string clean = temp.Write(".env", "LOG_LEVEL=debug");

        StagedFile staged = StagingWriter.CopyFile(clean, temp["staging", ".env"], null, secret: true);

        staged.HeldBack.Should().BeTrue();
        Directory.Exists(temp["staging"]).Should().BeFalse();
    }
}
