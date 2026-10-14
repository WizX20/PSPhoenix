using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class AtomicFileTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    [Fact]
    public void WriteAllText_writes_utf8_without_a_bom_and_creates_the_folder()
    {
        string path = temp["new", "folder", "config.json"];

        AtomicFile.WriteAllText(path, "{ \"name\": \"Zoë\" }");

        File.ReadAllBytes(path).Should().Equal(Encoding.UTF8.GetBytes("{ \"name\": \"Zoë\" }"));
    }

    [Fact]
    public void WriteAllText_replaces_a_file_and_leaves_no_temporary_one()
    {
        string path = temp.Write("config.json", "one");

        AtomicFile.WriteAllText(path, "two");

        File.ReadAllText(path).Should().Be("two");
        Directory.GetFiles(temp.Path).Should().ContainSingle();
    }

    [Fact]
    public void WriteAllText_takes_an_empty_text()
    {
        string path = temp["empty.txt"];

        AtomicFile.WriteAllText(path, "");

        new FileInfo(path).Length.Should().Be(0);
    }

    [Fact]
    public void A_write_that_fails_leaves_the_file_as_it_was_and_no_temporary_one()
    {
        string path = temp.Write("config.json", "one");
        // A folder in the place of the file: the rename onto it fails.
        string blocked = temp["blocked"];
        Directory.CreateDirectory(blocked);

        Action write = () => AtomicFile.WriteAllText(blocked, "two");

        write.Should().Throw<Exception>().Which.Should().Match(e => e is IOException || e is UnauthorizedAccessException);
        File.ReadAllText(path).Should().Be("one");
        Directory.GetFiles(temp.Path).Should().Equal(path);
    }

    [Fact]
    public void Copy_copies_a_file_into_place()
    {
        string source = temp.Write("source/a.bin", "content");
        string path = temp["target", "a.bin"];
        temp.Write("target/a.bin", "old");

        AtomicFile.Copy(source, path);

        File.ReadAllText(path).Should().Be("content");
        Directory.GetFiles(temp["target"]).Should().Equal(path);
    }

    [Fact]
    public void Copy_of_a_missing_source_throws_and_leaves_no_temporary_file()
    {
        string path = temp["target", "a.bin"];

        Action copy = () => AtomicFile.Copy(temp["missing.bin"], path);

        copy.Should().Throw<FileNotFoundException>();
        Directory.GetFiles(temp["target"]).Should().BeEmpty();
    }

    [Fact]
    public void A_reader_holding_the_file_open_only_delays_the_replace()
    {
        // On Windows an open file blocks the rename onto it; MoveIntoPlace waits for the reader. On
        // other platforms the rename never waits - the test then only shows it is not in the way.
        // The reader lets go on a thread of its own: a thread-pool task can start too late on a busy
        // runner, while this thread blocks in the retries.
        string path = temp.Write("held.txt", "one");
        FileStream reader = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Thread release = new(() =>
        {
            Thread.Sleep(200);
            reader.Dispose();
        });
        release.Start();

        AtomicFile.WriteAllText(path, "two");

        release.Join();
        File.ReadAllText(path).Should().Be("two");
    }

    [Fact]
    public void A_reader_that_never_lets_go_fails_the_replace_after_about_a_second()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "only Windows blocks a rename onto an open file");
        string path = temp.Write("held.txt", "one");
        using FileStream reader = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);

        Action write = () => AtomicFile.WriteAllText(path, "two");

        write.Should().Throw<Exception>().Which.Should().Match(e => e is IOException || e is UnauthorizedAccessException);
        reader.Dispose();
        File.ReadAllText(path).Should().Be("one");
        Directory.GetFiles(temp.Path).Should().Equal(path);
    }

    [Fact]
    public void TemporaryPath_is_a_unique_hidden_name_next_to_the_file()
    {
        string path = temp["sub", "phoenix.json"];

        string first = AtomicFile.TemporaryPath(path);
        string second = AtomicFile.TemporaryPath(path);

        Path.GetDirectoryName(first).Should().Be(temp["sub"]);
        Directory.Exists(temp["sub"]).Should().BeTrue();
        Path.GetFileName(first).Should().MatchRegex(@"^\.phoenix\.json\.[0-9a-f]{8}\.tmp$");
        second.Should().NotBe(first);
    }

    [Theory]
    [InlineData("relative.txt")]
    [InlineData("sub/relative.txt")]
    [InlineData("")]
    public void A_path_that_is_not_full_is_refused(string path)
    {
        Action write = () => AtomicFile.WriteAllText(path, "x");

        write.Should().Throw<ArgumentException>();
    }
}
