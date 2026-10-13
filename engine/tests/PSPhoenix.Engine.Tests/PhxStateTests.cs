using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class PhxStateTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private string StatePath => temp["state", "state.json"];

    private static readonly DateTime Started = new(2026, 10, 12, 8, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void Without_a_file_the_state_is_fresh()
    {
        PhxState state = PhxState.Load(StatePath);

        state.Version.Should().Be(1);
        state.LastRun.Should().BeNull();
        state.Providers.Should().BeEmpty();
        state.Files.Should().BeEmpty();
        state.Published.Should().BeEmpty();
        state.PublishedTo.Should().BeNull();
        state.Refs.Should().BeEmpty();
    }

    [Fact]
    public void Saves_and_reads_back_everything()
    {
        string file = temp.Write("a.txt", "one");
        PhxState state = new();
        FileTracker tracker = state.Tracker("claude");
        tracker.HasChanged(file);
        state.Succeeded("claude", Started, tracker);
        state.Failed("repos", "boom");
        state.PublishInto(@"D:\Target\Box");
        state.PublishedHashes("claude")["memory/a.md"] = "CD";
        state.Refs[@"C:\Repos\r"] = "EF";
        state.LastRun = new RunRecord(Started, ["claude", "repos"], ["repos"], @"C:\logs\run.log");

        state.Save(StatePath);
        PhxState read = PhxState.Load(StatePath);

        read.Providers["claude"].Should().Be(new ProviderState(Started, "ok"));
        read.Providers["repos"].Should().Be(new ProviderState(null, "failed: boom"));
        read.Files["claude"][file].Should().Be(tracker.Seen[file]);
        read.PublishedTo.Should().Be(@"D:\Target\Box");
        read.Published["claude"]["memory/a.md"].Should().Be("CD");
        read.Refs[@"C:\Repos\r"].Should().Be("EF");
        read.LastRun!.At.Should().Be(Started);
        read.LastRun.At.Kind.Should().Be(DateTimeKind.Utc);
        read.LastRun.Providers.Should().Equal("claude", "repos");
        read.LastRun.Failed.Should().Equal("repos");
        read.LastRun.Log.Should().Be(@"C:\logs\run.log");
    }

    [Fact]
    public void Reads_the_state_the_PowerShell_version_wrote()
    {
        // ConvertTo-Json -Compress of the state as PSPhoenix wrote it before the engine had it.
        File.WriteAllText(temp.Write("state/state.json", ""), """
            {"version":1,"lastRun":{"at":"2026-10-12T08:00:00.0000000Z","providers":["repos"],"failed":[],"log":"C:\\logs\\run-1.log"},"providers":{"repos":{"lastRun":"2026-10-12T08:00:00.0000000Z","lastResult":"ok"},"claude":{"lastRun":null,"lastResult":"failed: boom"}},"files":{"claude":{"C:\\Users\\x\\.claude\\a.md":{"size":3,"mtime":638956800000000000,"sha256":"AB"}}},"published":{"repos":{"repos.json":"CD"}},"publishedTo":"D:\\Target\\Box","refs":{}}
            """);

        PhxState state = PhxState.Load(StatePath);

        state.LastRun!.At.Should().Be(Started);
        state.LastRun.Log.Should().Be(@"C:\logs\run-1.log");
        state.LastRun.Providers.Should().Equal("repos");
        state.LastRun.Failed.Should().BeEmpty();
        state.Providers["repos"].Should().Be(new ProviderState(Started, "ok"));
        state.Providers["claude"].Should().Be(new ProviderState(null, "failed: boom"));
        state.Files["claude"][@"C:\Users\x\.claude\a.md"].Should().Be(new FileStamp(3, 638956800000000000, "AB"));
        state.Published["repos"]["repos.json"].Should().Be("CD");
        state.PublishedTo.Should().Be(@"D:\Target\Box");
    }

    [Fact]
    public void A_run_the_PowerShell_version_recorded_without_providers_has_none()
    {
        // @($providers.Name) of no providers is @($null): ConvertTo-Json wrote [null].
        File.WriteAllText(temp.Write("state/state.json", ""), """
            {"version":1,"lastRun":{"at":"2026-10-12T08:00:00.0000000Z","providers":[null],"failed":[null,""],"log":null}}
            """);

        PhxState state = PhxState.Load(StatePath);

        state.LastRun!.Providers.Should().BeEmpty();
        state.LastRun.Failed.Should().BeEmpty();
    }

    [Fact]
    public void Writes_compact_camel_case_json_without_a_bom_and_with_readable_paths()
    {
        PhxState state = new();
        state.Refs[@"C:\Repos\Zoë"] = "AB";

        state.Save(StatePath);

        byte[] bytes = File.ReadAllBytes(StatePath);
        bytes.Take(3).Should().NotEqual(Encoding.UTF8.GetPreamble());
        string json = Encoding.UTF8.GetString(bytes);
        json.Should().StartWith("{\"version\":1,\"lastRun\":null,\"providers\":{},\"files\":{},\"published\":{},\"publishedTo\":null,");
        json.Should().Contain("\"refs\":{\"C:\\\\Repos\\\\Zoë\":\"AB\"}");
        Directory.GetFiles(temp["state"]).Should().Equal(StatePath);
    }

    [Theory]
    [InlineData("{ broken", "not a state this PSPhoenix wrote")]
    [InlineData("[]", "not a state this PSPhoenix wrote")]
    [InlineData("{}", "not a state this PSPhoenix wrote")]
    [InlineData("{ \"version\": 0 }", "not a state this PSPhoenix wrote")]
    [InlineData("{ \"version\": 99, \"files\": { \"x\": {} } }", "written by a newer PSPhoenix (version 99)")]
    [InlineData("{ \"version\": 1, \"files\": [] }", "not a state this PSPhoenix wrote")]
    public void A_file_this_PSPhoenix_did_not_write_is_refused_with_why(string json, string why)
    {
        File.WriteAllText(temp.Write("state/state.json", ""), json);

        Action load = () => PhxState.Load(StatePath);

        load.Should().Throw<InvalidDataException>().WithMessage(why + "*");
    }

    [Fact]
    public void Empty_entries_are_skipped()
    {
        File.WriteAllText(temp.Write("state/state.json", ""), """
            {"version":1,"providers":{"repos":null},"files":{"claude":null,"wip":{"C:\\a":null}},"published":{"repos":null},"refs":{"C:\\r":null}}
            """);

        PhxState state = PhxState.Load(StatePath);

        state.Providers.Should().BeEmpty();
        state.Files["claude"].Should().BeEmpty();
        state.Files["wip"].Should().BeEmpty();
        state.Published["repos"].Should().BeEmpty();
        state.Refs.Should().BeEmpty();
    }

    [Fact]
    public void Times_are_read_as_utc()
    {
        File.WriteAllText(temp.Write("state/state.json", ""), """
            {"version":1,"lastRun":{"at":"2026-10-12T10:00:00+02:00","providers":[],"failed":[]},"providers":{"repos":{"lastRun":"2026-10-12T08:00:00","lastResult":"ok"}}}
            """);

        PhxState state = PhxState.Load(StatePath);

        state.LastRun!.At.Should().Be(Started);
        state.LastRun.At.Kind.Should().Be(DateTimeKind.Utc);
        state.Providers["repos"].LastRun.Should().Be(Started);
        state.Providers["repos"].LastRun!.Value.Kind.Should().Be(DateTimeKind.Utc);
    }

    [Fact]
    public void Provider_names_ignore_case_and_paths_compare_as_the_platform_compares_them()
    {
        File.WriteAllText(temp.Write("state/state.json", ""), """
            {"version":1,"files":{"Claude":{"C:\\Users\\x\\a.md":{"size":1,"mtime":1,"sha256":"A"}}},"refs":{"C:\\Repos\\R":"B"}}
            """);

        PhxState state = PhxState.Load(StatePath);

        state.Files.Should().ContainKey("claude");
        state.Files["claude"].ContainsKey(@"c:\users\X\A.MD").Should().Be(OperatingSystem.IsWindows());
        state.Refs.ContainsKey(@"c:\repos\r").Should().Be(OperatingSystem.IsWindows());
    }

    [Fact]
    public void A_failure_keeps_the_last_successful_run_and_what_it_saw()
    {
        string file = temp.Write("a.txt", "one");
        PhxState state = new();
        FileTracker first = state.Tracker("claude");
        first.HasChanged(file);
        state.Succeeded("claude", Started, first);

        FileTracker second = state.Tracker("claude");
        second.Known.Should().ContainKey(file);
        state.Failed("claude", "disk full");

        state.Providers["claude"].Should().Be(new ProviderState(Started, "failed: disk full"));
        state.Files["claude"].Should().ContainKey(file);
        state.Tracker("repos").Known.Should().BeEmpty();
    }

    [Fact]
    public void A_success_keeps_what_this_run_saw_and_drops_the_rest()
    {
        string kept = temp.Write("kept.txt", "x");
        string dropped = temp.Write("dropped.txt", "x");
        PhxState state = new();
        FileTracker first = state.Tracker("claude");
        first.HasChanged(kept);
        first.HasChanged(dropped);
        state.Succeeded("claude", Started, first);

        FileTracker second = state.Tracker("claude");
        second.HasChanged(kept);
        state.Succeeded("claude", Started.AddHours(1), second);

        state.Files["claude"].Keys.Should().Equal(kept);
        state.Providers["claude"].LastRun.Should().Be(Started.AddHours(1));
    }

    [Fact]
    public void Hashes_published_into_another_snapshot_folder_are_dropped()
    {
        PhxState state = new();
        state.PublishInto(@"D:\Target\Box");
        state.PublishedHashes("repos")["repos.json"] = "AB";

        state.PublishInto(OperatingSystem.IsWindows() ? @"d:\target\box" : @"D:\Target\Box");
        state.PublishedHashes("repos").Should().ContainKey("repos.json");

        state.PublishInto(@"D:\Target\Desk");
        state.PublishedTo.Should().Be(@"D:\Target\Desk");
        state.Published.Should().BeEmpty();
        state.PublishedHashes("repos").Should().BeEmpty();
        state.PublishedHashes("repos").Should().BeSameAs(state.Published["repos"]);
    }
}
