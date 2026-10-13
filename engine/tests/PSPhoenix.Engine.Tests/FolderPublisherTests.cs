namespace PSPhoenix.Engine.Tests;

public sealed class FolderPublisherTests : IDisposable
{
    private readonly TempFolder temp = new();
    private readonly List<string> hashed = [];

    public void Dispose() => temp.Dispose();

    private string Source => temp["staging"];

    private string Destination => temp["snapshot", "repos"];

    private void Stage(string relative, string content) => temp.Write(Path.Combine("staging", relative), content);

    private void Unstage(string relative) => File.Delete(Path.Combine(Source, relative));

    private string Published(string relative) => File.ReadAllText(Path.Combine(Destination, relative));

    /// <summary>Publishes, recording every file the publisher hashes.</summary>
    private PublishResult Publish(IDictionary<string, string>? published = null)
        => FolderPublisher.Publish(Source, Destination, published, path =>
        {
            hashed.Add(path);
            return FileHash.Sha256(path);
        });

    private static Dictionary<string, string> NewPublished()
        => new(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);

    private string[] DestinationFiles()
        => Directory.EnumerateFiles(Destination, "*", SearchOption.AllDirectories)
            .Select(file => Path.GetRelativePath(Destination, file).Replace('\\', '/'))
            .Order(StringComparer.Ordinal)
            .ToArray();

    [Fact]
    public void Publishes_every_staged_file_into_a_new_folder()
    {
        Stage("repos.json", "{}");
        Stage("github.com/o/r/.env.age", "secret");

        PublishResult result = Publish();

        result.Should().Be(new PublishResult(Written: 2, Unchanged: 0, Removed: 0, Files: 2));
        DestinationFiles().Should().Equal("github.com/o/r/.env.age", "repos.json");
        Published("repos.json").Should().Be("{}");
    }

    [Fact]
    public void Writes_nothing_when_nothing_changed()
    {
        Stage("repos.json", "one");
        Stage("sub/extra.txt", "two");
        Publish();
        string[] before = Directory.EnumerateFiles(Destination, "*", SearchOption.AllDirectories)
            .Select(file => $"{file}|{File.GetLastWriteTimeUtc(file).Ticks}").Order().ToArray();

        PublishResult result = Publish();

        result.Should().Be(new PublishResult(Written: 0, Unchanged: 2, Removed: 0, Files: 2));
        Directory.EnumerateFiles(Destination, "*", SearchOption.AllDirectories)
            .Select(file => $"{file}|{File.GetLastWriteTimeUtc(file).Ticks}").Order().Should().Equal(before);
    }

    [Fact]
    public void Writes_a_changed_file_and_removes_what_is_no_longer_staged_with_the_folders_left_empty()
    {
        Stage("repos.json", "one");
        Stage("deep/er/old.txt", "old");
        Publish();
        Stage("repos.json", "changed");
        Unstage("deep/er/old.txt");
        // A temporary file a crashed run left behind goes too.
        File.WriteAllText(Path.Combine(Destination, ".repos.json.0123abcd.tmp"), "half");

        PublishResult result = Publish();

        result.Should().Be(new PublishResult(Written: 1, Unchanged: 0, Removed: 2, Files: 1));
        Published("repos.json").Should().Be("changed");
        DestinationFiles().Should().Equal("repos.json");
        Directory.Exists(Path.Combine(Destination, "deep")).Should().BeFalse();
    }

    [Fact]
    public void A_missing_source_empties_the_destination()
    {
        Stage("repos.json", "one");
        Publish();
        Directory.Delete(Source, recursive: true);

        PublishResult result = Publish();

        result.Should().Be(new PublishResult(Written: 0, Unchanged: 0, Removed: 1, Files: 0));
        DestinationFiles().Should().BeEmpty();
    }

    [Fact]
    public void Without_published_hashes_an_existing_file_is_compared_by_reading_it()
    {
        Stage("repos.json", "one");
        Publish();
        hashed.Clear();

        Publish().Unchanged.Should().Be(1);

        hashed.Should().Contain(Path.Combine(Destination, "repos.json"));
    }

    [Fact]
    public void Published_hashes_spare_reading_the_destination_back()
    {
        // Reading a published file back would download it from OneDrive.
        Stage("repos.json", "one");
        Stage("gone.txt", "soon gone");
        Dictionary<string, string> published = NewPublished();
        Publish(published);
        published.Keys.Order(StringComparer.Ordinal).Should().Equal("gone.txt", "repos.json");
        published["repos.json"].Should().Be(FileHash.Sha256Text("one"));
        Unstage("gone.txt");
        hashed.Clear();

        PublishResult result = Publish(published);

        result.Should().Be(new PublishResult(Written: 0, Unchanged: 1, Removed: 1, Files: 1));
        hashed.Should().NotContain(path => path.StartsWith(Destination, StringComparison.Ordinal));
        published.Keys.Should().Equal("repos.json");
    }

    [Fact]
    public void A_published_hash_does_not_hide_a_file_changed_or_gone_in_the_destination()
    {
        Stage("changed.txt", "one");
        Stage("gone.txt", "two");
        Stage("same-length.txt", "abc");
        Dictionary<string, string> published = NewPublished();
        Publish(published);
        File.WriteAllText(Path.Combine(Destination, "changed.txt"), "something else entirely");
        File.Delete(Path.Combine(Destination, "gone.txt"));

        PublishResult result = Publish(published);

        // A file of the same length that somebody else changed is trusted to the hash: reading
        // it back is exactly what the published hashes are there to avoid.
        result.Should().Be(new PublishResult(Written: 2, Unchanged: 1, Removed: 0, Files: 3));
        Published("changed.txt").Should().Be("one");
        Published("gone.txt").Should().Be("two");
    }

    [Fact]
    public void Swaps_a_file_for_a_folder_of_the_same_name_and_back()
    {
        Stage("foo", "a file");
        Publish();
        Unstage("foo");
        Stage("foo/bar.txt", "in a folder");

        Publish().Written.Should().Be(1);
        Published("foo/bar.txt").Should().Be("in a folder");

        Directory.Delete(Path.Combine(Source, "foo"), recursive: true);
        Stage("foo", "a file again");

        Publish().Written.Should().Be(1);
        Published("foo").Should().Be("a file again");
    }

    [Fact]
    public void Publishes_a_rename_that_only_changes_case_and_keeps_the_new_spelling_in_the_hashes()
    {
        Stage("Memory.md", "same");
        Dictionary<string, string> published = NewPublished();
        Publish(published);
        Unstage("Memory.md");
        Stage("memory.md", "same");

        PublishResult result = Publish(published);

        // Removed and copied again under the new name - not counted as a removal.
        result.Should().Be(new PublishResult(Written: 1, Unchanged: 0, Removed: 0, Files: 1));
        DestinationFiles().Should().Equal("memory.md");
        published.Keys.Should().Equal("memory.md");
    }

    [Fact]
    public void Publishes_hidden_files()
    {
        Stage(".gitconfig", "[user]");
        Stage(".config/tool.json", "{}");

        Publish().Written.Should().Be(2);

        DestinationFiles().Should().Equal(".config/tool.json", ".gitconfig");
    }

    [Fact]
    public void A_file_that_cannot_be_read_names_itself_and_drops_out_of_the_published_hashes()
    {
        Stage("a.txt", "one");
        Stage("b.txt", "two");
        Dictionary<string, string> published = NewPublished();
        Publish(published);
        string broken = Path.Combine(Source, "b.txt");

        Action publish = () => FolderPublisher.Publish(Source, Destination, published,
            path => path == broken ? throw new IOException("the disk said no") : FileHash.Sha256(path));

        PublishException failure = publish.Should().Throw<PublishException>().Which;
        failure.Message.Should().Be("b.txt: the disk said no");
        failure.RelativePath.Should().Be("b.txt");
        published.Keys.Should().Equal("a.txt");
    }

    [Fact]
    public void A_file_held_open_in_the_destination_names_itself()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "only Windows keeps an open file from being removed");
        Stage("kept.txt", "one");
        Stage("old.txt", "two");
        Publish();
        Unstage("old.txt");
        using FileStream holder = new(Path.Combine(Destination, "old.txt"), FileMode.Open, FileAccess.Read, FileShare.Read);

        Action publish = () => Publish();

        publish.Should().Throw<PublishException>().Which.RelativePath.Should().Be("old.txt");
    }

    [Fact]
    public void SameContent_compares_the_length_first_and_the_hashes_only_then()
    {
        string source = temp.Write("a/file.txt", "abc");
        string same = temp.Write("b/file.txt", "abc");
        string sameLength = temp.Write("c/file.txt", "xyz");
        string longer = temp.Write("d/file.txt", "abcd");
        List<string> read = [];
        string Hash(string path)
        {
            read.Add(path);
            return FileHash.Sha256(path);
        }

        FolderPublisher.SameContent(source, same, null, Hash).Should().BeTrue();
        FolderPublisher.SameContent(source, sameLength, null, Hash).Should().BeFalse();
        read.Clear();
        FolderPublisher.SameContent(source, longer, null, Hash).Should().BeFalse();
        FolderPublisher.SameContent(source, temp["missing.txt"], null, Hash).Should().BeFalse();
        read.Should().BeEmpty();
        FolderPublisher.SameContent(source, same, FileHash.Sha256Text("abc"), Hash).Should().BeTrue();
        read.Should().Equal(same);
    }

    [Theory]
    [InlineData("relative", true)]
    [InlineData("relative", false)]
    public void Paths_that_are_not_full_are_refused(string path, bool asSource)
    {
        Action publish = () => FolderPublisher.Publish(asSource ? path : Source, asSource ? Destination : path, null);

        publish.Should().Throw<ArgumentException>();
    }
}
