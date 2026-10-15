using System.Text.Json.Nodes;

namespace PSPhoenix.Engine.Tests;

public sealed class ClaudeMcpTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private string Repo(string name) => temp["Repos", name];

    private const string Source = """
        {
          "oauthAccount": { "emailAddress": "someone@example.invalid" },
          "firstStartTime": "2026-03-01T08:15:05.600Z",
          "numStartups": 1234567890123,
          "mcpServers": { "github": { "command": "gh-mcp", "env": { "TOKEN": "x" } } },
          "projects": {
            "C:/Repos/App": { "allowedTools": [], "mcpServers": { "local": { "command": "a" } } },
            "c:/Repos/App": { "mcpServers": { "lower": { "command": "b" } } },
            "C:/Other": { "allowedTools": [] }
          }
        }
        """;

    [Fact]
    public void Backs_up_only_the_servers_and_keeps_keys_that_differ_in_case()
    {
        string path = temp.Write(".claude.json", Source);

        McpBackup backup = ClaudeMcp.Backup(path, [new McpRepository("github.com/o/app", "C:\\Repos", "App", "C:\\Repos\\App")])!;

        backup.Servers.Should().Be(3);
        JsonObject json = JsonNode.Parse(backup.Json)!.AsObject();
        json.ContainsKey("oauthAccount").Should().BeFalse();
        json["projects"]!.AsObject().Select(p => p.Key).Should().Equal("C:/Repos/App", "c:/Repos/App");
        json["mcpServers"]!["github"]!["env"]!["TOKEN"]!.GetValue<string>().Should().Be("x");
        if (OperatingSystem.IsWindows())
        {
            json["projects"]!["C:/Repos/App"]!["identity"]!.GetValue<string>().Should().Be("github.com/o/app");
        }
    }

    [Fact]
    public void Has_nothing_to_back_up_without_servers_or_a_file()
    {
        ClaudeMcp.Backup(temp["missing.json"], []).Should().BeNull();
        ClaudeMcp.Backup(temp.Write("empty.json", "{ \"projects\": { \"x\": {} } }"), []).Should().BeNull();
    }

    [Fact]
    public void Merges_into_a_new_file_and_under_the_new_project_key()
    {
        string backup = ClaudeMcp.Backup(temp.Write("old.json", Source), [])!.Json;
        string target = temp["new", ".claude.json"];
        Dictionary<string, string?> keys = new() { ["C:/Repos/App"] = "D:/src/App", ["c:/Repos/App"] = null };

        IReadOnlyList<McpChange> changes = ClaudeMcp.Merge(target, backup, keys, dryRun: false);

        changes.Select(c => (c.Server, c.Where, c.Outcome)).Should().Equal(
            ("github", "user", McpOutcome.Added),
            ("local", "D:/src/App", McpOutcome.Added));
        JsonObject json = JsonNode.Parse(File.ReadAllText(target))!.AsObject();
        json["projects"]!["D:/src/App"]!["mcpServers"]!["local"]!["command"]!.GetValue<string>().Should().Be("a");
    }

    [Fact]
    public void Leaves_the_rest_of_the_file_as_it_was_and_a_server_that_is_there_alone()
    {
        string backup = ClaudeMcp.Backup(temp.Write("old.json", Source), [])!.Json;
        string target = temp.Write("target.json", Source.Replace("\"gh-mcp\"", "\"mine\"").Replace("\"mcpServers\": { \"local\": { \"command\": \"a\" } }", "\"mcpServers\": {}"));

        IReadOnlyList<McpChange> changes = ClaudeMcp.Merge(target, backup, new Dictionary<string, string?> { ["C:/Repos/App"] = "C:/Repos/App" }, dryRun: false);

        changes.Select(c => (c.Server, c.Outcome)).Should().Equal(("github", McpOutcome.Differs), ("local", McpOutcome.Added));
        string text = File.ReadAllText(target);
        text.Should().Contain("\"2026-03-01T08:15:05.600Z\"").And.Contain("1234567890123").And.Contain("\"mine\"");
        JsonNode.Parse(text)!["projects"]!.AsObject().Select(p => p.Key).Should().Equal("C:/Repos/App", "c:/Repos/App", "C:/Other");
    }

    [Fact]
    public void Writes_nothing_when_nothing_is_added_or_on_a_dry_run()
    {
        string path = temp.Write(".claude.json", Source);
        string backup = ClaudeMcp.Backup(path, [])!.Json;
        DateTime before = File.GetLastWriteTimeUtc(path);

        ClaudeMcp.Merge(path, backup, new Dictionary<string, string?> { ["C:/Repos/App"] = "C:/Repos/App" }, dryRun: false)
            .Should().OnlyContain(c => c.Outcome == McpOutcome.Present);
        ClaudeMcp.Merge(temp["none.json"], backup, new Dictionary<string, string?>(), dryRun: true).Should().NotBeEmpty();

        File.GetLastWriteTimeUtc(path).Should().Be(before);
        File.ReadAllText(path).Should().Be(Source);
        File.Exists(temp["none.json"]).Should().BeFalse();
    }

    [Fact]
    public void Lists_the_projects_of_a_backup()
    {
        string backup = ClaudeMcp.Backup(temp.Write("old.json", Source), [new McpRepository("github.com/o/app", "C:\\Repos", "App", "C:\\Repos\\App")])!.Json;

        ClaudeMcp.Projects(backup).Select(p => p.Key).Should().Equal("C:/Repos/App", "c:/Repos/App");
    }
}
