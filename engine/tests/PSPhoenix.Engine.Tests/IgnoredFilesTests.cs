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
    [InlineData("/config.env", "sub/config.env", false)]
    [InlineData("/leftover/", "leftover/a.txt", true)]
    [InlineData("/leftover/", "src/leftover/a.txt", false)]
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
        temp.Write("leftover/.pytest_cache/v/cache/lastfailed", "{}");

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
        temp.Write(".claude/scheduled_tasks.lock", "x");
        temp.Write(".flutter-plugins-dependencies", "{}");
        temp.Write("logo.PNG", "x");
        temp.Write("dump.json", new string('x', 2000));
        temp.Write("ok.json", "{}");

        Dictionary<string, CandidateFilter> filters = List("lib/model.g.dart", "package-lock.json", "debug.log", ".claude/scheduled_tasks.lock", ".flutter-plugins-dependencies", "logo.PNG", "dump.json", "ok.json")
            .Files.ToDictionary(f => f.Path, f => f.Filter);

        filters.Should().BeEquivalentTo(new Dictionary<string, CandidateFilter>
        {
            ["lib/model.g.dart"] = CandidateFilter.Generated,
            ["package-lock.json"] = CandidateFilter.Generated,
            ["debug.log"] = CandidateFilter.Noise,
            [".claude/scheduled_tasks.lock"] = CandidateFilter.Noise,
            [".flutter-plugins-dependencies"] = CandidateFilter.Generated,
            ["logo.PNG"] = CandidateFilter.Binary,
            ["dump.json"] = CandidateFilter.Large,
            ["ok.json"] = CandidateFilter.None,
        });
    }

    [Fact]
    public void Classifies_secrets_by_name_and_by_the_repository_s_own_patterns()
    {
        foreach (string name in new[] { ".env", ".env.local", "secrets.json", "cert.pfx", "server.pem", "api.key", "id_ed25519", "deploy.conf", "plain.txt",
            "release.jks", "upload.keystore", "server.ppk", ".netrc", "_netrc", ".pgpass", "vault.kdbx" })
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
    public void An_oversized_folder_is_one_entry_and_the_walk_goes_on()
    {
        string folder = temp["many"];
        Directory.CreateDirectory(folder);
        for (int i = 0; i <= IgnoredFiles.FolderCap; i++)
        {
            File.WriteAllBytes(Path.Combine(folder, $"f{i}.txt"), [1]);
        }
        temp.Write("web/.env.local", "x");

        IgnoredFileList list = List("many/", "web/.env.local");

        list.Truncated.Should().BeFalse();
        list.Files.Select(f => (f.Path, f.Filter)).Should().Equal(("many/", CandidateFilter.TooMany), ("web/.env.local", CandidateFilter.None));
        list.Files[0].Count.Should().BeGreaterThan(IgnoredFiles.FolderCap);
    }

    [Fact]
    public void A_folder_a_pattern_reaches_into_has_no_cap()
    {
        string folder = temp["many"];
        Directory.CreateDirectory(folder);
        for (int i = 0; i <= IgnoredFiles.FolderCap; i++)
        {
            File.WriteAllBytes(Path.Combine(folder, $"f{i}.txt"), [1]);
        }

        IgnoredFileList list = IgnoredFiles.List(temp.Path, ["many/"], 1024, new FileRules(include: ["/many/f7.txt"]));

        list.Files.Should().HaveCount(IgnoredFiles.FolderCap + 1);
    }

    [Fact]
    public void Lists_a_file_git_reports_in_a_tracked_folder_named_like_a_denied_one()
    {
        // An npm/pnpm workspace: packages/ is source, its .env.local is ignored on its own.
        temp.Write("packages/web/.env.local", "x");
        temp.Write("build/tools/local.json", "{}");
        temp.Write("packages/web/node_modules/x/index.js", "x");

        List("packages/web/.env.local", "build/tools/local.json", "packages/web/node_modules/").Files.Select(f => f.Path)
            .Should().Equal("build/tools/local.json", "packages/web/.env.local");
    }

    [Fact]
    public void Does_not_enter_a_folder_the_review_excluded()
    {
        temp.Write("leftover/a.txt", "x");
        temp.Write("leftover/sub/b.txt", "x");
        temp.Write("other/c.txt", "x");

        IgnoredFiles.List(temp.Path, ["leftover/", "other/"], 1024, new FileRules(exclude: ["/leftover/", "other/sub/"])).Files.Select(f => f.Path)
            .Should().Equal("other/c.txt");
    }

    [Fact]
    public void Enters_an_excluded_or_denied_folder_only_for_what_a_pattern_names()
    {
        temp.Write("leftover/keep.txt", "x");
        temp.Write("leftover/drop.txt", "x");
        temp.Write("bin/special.json", "{}");
        temp.Write("bin/App.dll", "x");

        IgnoredFiles.List(temp.Path, ["leftover/", "bin/"], 1024, new FileRules(include: ["/leftover/keep.txt", "/bin/special.json"], exclude: ["/leftover/"])).Files.Select(f => f.Path)
            .Should().Equal("bin/special.json", "leftover/drop.txt", "leftover/keep.txt");
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
    public void A_repository_s_own_decision_beats_the_one_for_every_repository()
    {
        FileRules every = new(include: ["/.env", "*.local.json"], secret: ["/keys.txt"], exclude: ["/tmp/"]);
        FileRules rules = new(exclude: ["/.env"], include: ["/tmp/keep.txt"], everyRepository: every);

        rules.Decide(File(".env", secretName: true)).Should().Be(FileDecision.Exclude);
        rules.Decide(File("app.local.json")).Should().Be(FileDecision.Include);
        rules.Decide(File("keys.txt")).Should().Be(FileDecision.Secret);
        rules.Decide(File("tmp/keep.txt")).Should().Be(FileDecision.Include);
        rules.Decide(File("tmp/other.txt")).Should().Be(FileDecision.Exclude);
        rules.Decide(File("notes.md")).Should().Be(FileDecision.Pending);
        rules.Decide(File("big.local.json", filter: CandidateFilter.Large)).Should().Be(FileDecision.Exclude);
        rules.Names("x/app.local.json").Should().BeTrue();
        rules.Prunes("tmp").Should().BeFalse();
        new FileRules(everyRepository: new FileRules(exclude: ["/tmp/"])).Prunes("tmp").Should().BeTrue();
        // *.local.json for every repository can match inside it.
        new FileRules(everyRepository: every).Prunes("tmp").Should().BeFalse();
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

    [Fact]
    public void Only_a_pattern_naming_one_file_overrides_a_built_in_filter()
    {
        FileRules folder = new(include: ["dumps/"], secret: ["*.bak.json"]);
        FileRules exact = new(include: ["/dumps/big.json"]);

        folder.Decide(File("dumps/big.json", filter: CandidateFilter.Large)).Should().Be(FileDecision.Exclude);
        folder.Decide(File("dumps/small.json")).Should().Be(FileDecision.Include);
        folder.Decide(File("x.bak.json", filter: CandidateFilter.Large)).Should().Be(FileDecision.Exclude);
        exact.Decide(File("dumps/big.json", filter: CandidateFilter.Large)).Should().Be(FileDecision.Include);
    }

    [Theory]
    [InlineData("/leftover/", "leftover", true)]
    [InlineData("/leftover/", "other", false)]
    [InlineData("/notes.md", "leftover", false)]
    [InlineData("src/**/local.json", "src/app", true)]
    [InlineData("src/**/local.json", "lib", false)]
    [InlineData("**/local.json", "lib", true)]
    [InlineData("local.json", "lib", true)]
    [InlineData("/src/app/x.json", "src", true)]
    public void Knows_whether_a_pattern_reaches_into_a_folder(string pattern, string folder, bool expected)
    {
        new FileRules(include: [pattern]).Reaches(folder).Should().Be(expected);
    }

    [Fact]
    public void Only_an_anchored_pattern_inside_a_folder_points_into_it()
    {
        new FileRules(include: ["/bin/special.json"]).PointsInto("bin").Should().BeTrue();
        new FileRules(include: ["/leftover/"]).PointsInto("leftover/src/bin").Should().BeFalse();
        new FileRules(include: ["leftover/"]).PointsInto("leftover/src/bin").Should().BeFalse();
        new FileRules(include: ["*.json"]).PointsInto("bin").Should().BeFalse();
    }

    [Fact]
    public void A_folder_include_does_not_open_the_denied_folders_inside_it()
    {
        using TempFolder temp = new();
        temp.Write("leftover/keep.txt", "x");
        temp.Write("leftover/src/bin/app.config", "x");

        IgnoredFiles.List(temp.Path, ["leftover/"], 1024, new FileRules(include: ["leftover/"])).Files.Select(f => f.Path)
            .Should().Equal("leftover/keep.txt");
    }

    [Fact]
    public void Prunes_a_folder_only_when_an_exclude_covers_it_and_nothing_reaches_in()
    {
        new FileRules(exclude: ["/leftover/"]).Prunes("leftover").Should().BeTrue();
        new FileRules(exclude: ["*.log"]).Prunes("leftover").Should().BeFalse();
        new FileRules(exclude: ["/leftover/"], include: ["/leftover/keep.txt"]).Prunes("leftover").Should().BeFalse();
        new FileRules(exclude: ["/leftover/"], include: ["/notes.md"]).Prunes("leftover").Should().BeTrue();
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
    public void A_finding_the_review_overruled_does_not_make_a_file_secret_but_another_one_does()
    {
        string source = temp.Write("appsettings.json", "{ \"ClientSecret\": \"Zx9Qw3Er7Ty1Ui5Op2As8Df4\" }");
        Sealer sealer = new(Key.Recipient, temp["sealed"]);
        SecretFinding finding = SecretScanner.ScanFile(source).Findings.Single();
        finding.Signature.Should().Be("SecretValue:ClientSecret");

        StagedFile plain = StagingWriter.CopyFile(source, temp["staging", "appsettings.json"], sealer, false, [finding.Signature]);

        plain.Sealed.Should().BeFalse();
        plain.Scan.HasSecret.Should().BeFalse();
        System.IO.File.Exists(temp["staging", "appsettings.json"]).Should().BeTrue();

        System.IO.File.WriteAllText(source, "{ \"ClientSecret\": \"Zx9Qw3Er7Ty1Ui5Op2As8Df4\", \"token\": \"" + Fake.GitHubToken() + "\" }");
        StagedFile again = StagingWriter.CopyFile(source, temp["staging2", "appsettings.json"], sealer, false, [finding.Signature]);

        again.Sealed.Should().BeTrue();
        again.Scan.Findings.Should().ContainSingle().Which.Kind.Should().Be(SecretKind.GitHubToken);
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
