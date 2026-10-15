namespace PSPhoenix.Engine.Tests;

public sealed class IncrementalStagerTests : IDisposable
{
    private static readonly AgeKey Key = Age.NewKey();
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private string Staging => temp["staging"];

    private Stager NewStager(IReadOnlyDictionary<string, StagedRecord>? previous = null, string? recipient = null) =>
        new(Staging, new Sealer(recipient ?? Key.Recipient, temp["sealed"]), previous);

    [Fact]
    public void Keeps_an_unchanged_file_as_the_last_run_staged_it()
    {
        string source = temp.Write("src/notes.md", "my notes");
        Stager first = NewStager();
        first.CopyFile(source, temp["staging", "notes.md"]);
        DateTime written = File.GetLastWriteTimeUtc(temp["staging", "notes.md"]);

        Stager second = NewStager(first.Records);
        StagedEntry entry = second.CopyFile(source, temp["staging", "notes.md"]);

        second.Reused.Should().Be(1);
        entry.Should().Match<StagedEntry>(e => e.As == StagedAs.Plain && e.Stored == "notes.md");
        File.GetLastWriteTimeUtc(temp["staging", "notes.md"]).Should().Be(written);
        second.KnownHash("notes.md").Should().Be(FileHash.Sha256(temp["staging", "notes.md"]));
    }

    [Fact]
    public void Stages_again_what_changed_its_source_its_options_or_its_staged_copy()
    {
        string source = temp.Write("src/notes.md", "my notes");
        Stager first = NewStager();
        first.CopyFile(source, temp["staging", "notes.md"]);

        File.WriteAllText(source, "changed notes, longer");
        NewStager(first.Records).Should().Match<Stager>(s => s.CopyFile(source, temp["staging", "notes.md"], false, null).As == StagedAs.Plain && s.Reused == 0);
        File.ReadAllText(temp["staging", "notes.md"]).Should().Be("changed notes, longer");

        Stager third = NewStager(first.Records);
        third.CopyFile(source, temp["staging", "notes.md"], secret: true);
        third.Reused.Should().Be(0);
        File.Exists(temp["staging", "notes.md"]).Should().BeFalse("a file sealed now leaves no plain copy behind");
        File.Exists(temp["staging", "notes.md.age"]).Should().BeTrue();
    }

    [Fact]
    public void Seals_again_for_a_new_key()
    {
        string source = temp.Write("src/.env", "A=1");
        Stager first = NewStager();
        first.CopyFile(source, temp["staging", ".env"], secret: true);

        Stager second = NewStager(first.Records, Age.NewKey().Recipient);
        second.CopyFile(source, temp["staging", ".env"], secret: true);

        second.Reused.Should().Be(0);
    }

    [Fact]
    public void Keeps_an_unchanged_text_and_writes_a_changed_one()
    {
        Stager first = NewStager();
        first.WriteText(temp["staging", "files.json"], "{ \"a\": 1 }");

        Stager second = NewStager(first.Records);
        second.WriteText(temp["staging", "files.json"], "{ \"a\": 1 }");
        second.WriteText(temp["staging", "other.json"], "{}");

        second.Reused.Should().Be(1);
    }

    [Fact]
    public void Prunes_what_this_run_did_not_stage_but_not_what_was_written_around_it()
    {
        string kept = temp.Write("src/kept.md", "kept");
        string dropped = temp.Write("src/dropped.md", "dropped");
        Stager first = NewStager();
        first.CopyFile(kept, temp["staging", "kept.md"]);
        first.CopyFile(dropped, temp["staging", "sub", "dropped.md"]);
        DateTime start = DateTime.UtcNow.AddSeconds(1);
        File.SetLastWriteTimeUtc(temp["staging", "kept.md"], start.AddSeconds(-5));
        File.SetLastWriteTimeUtc(temp["staging", "sub", "dropped.md"], start.AddSeconds(-5));

        Stager second = NewStager(first.Records);
        second.CopyFile(kept, temp["staging", "kept.md"]);
        string around = temp.Write(Path.Combine("staging", "around.txt"), "written around the stager");
        File.SetLastWriteTimeUtc(around, start.AddSeconds(1));

        second.Prune(start).Should().Be(1);
        File.Exists(temp["staging", "kept.md"]).Should().BeTrue();
        File.Exists(around).Should().BeTrue();
        Directory.Exists(temp["staging", "sub"]).Should().BeFalse();
    }

    [Fact]
    public void The_state_keeps_what_was_staged()
    {
        string source = temp.Write("src/token.txt", "token " + Fake.GitHubToken());
        Stager stager = NewStager();
        stager.CopyFile(source, temp["staging", "token.txt"]);
        PhxState state = new();
        state.KeepStaged("claude", stager.Records);
        state.Save(temp["state.json"]);

        IReadOnlyDictionary<string, StagedRecord> loaded = PhxState.Load(temp["state.json"]).StagedBy("claude");

        loaded["token.txt"].Should().Match<StagedRecord>(r => r.As == StagedAs.Sealed && r.Stored == "token.txt.age" && r.Findings.Count == 1);
        loaded["token.txt"].Findings[0].Kind.Should().Be(SecretKind.GitHubToken);
        NewStager(loaded).Should().Match<Stager>(s => s.CopyFile(source, temp["staging", "token.txt"], false, null).As == StagedAs.Sealed && s.Reused == 1);
    }
}
