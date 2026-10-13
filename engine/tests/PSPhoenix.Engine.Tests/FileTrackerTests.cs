namespace PSPhoenix.Engine.Tests;

public sealed class FileTrackerTests : IDisposable
{
    private readonly TempFolder temp = new();
    private readonly List<string> hashed = [];

    public void Dispose() => temp.Dispose();

    /// <summary>A tracker for the next run, recording every file it hashes.</summary>
    private FileTracker Next(IReadOnlyDictionary<string, FileStamp>? known = null)
        => new(known, path =>
        {
            hashed.Add(path);
            return FileHash.Sha256(path);
        });

    [Fact]
    public void A_new_file_has_changed_and_is_seen_with_its_size_mtime_and_hash()
    {
        string file = temp.Write("a.txt", "one");
        FileTracker run = Next();

        run.HasChanged(file).Should().BeTrue();

        run.Seen[file].Should().Be(new FileStamp(3, File.GetLastWriteTimeUtc(file).Ticks, FileHash.Sha256Text("one")));
    }

    [Fact]
    public void A_file_with_the_size_and_mtime_its_last_run_saw_is_not_hashed()
    {
        string file = temp.Write("a.txt", "one");
        FileTracker first = Next();
        first.HasChanged(file);
        hashed.Clear();

        FileTracker next = Next(first.Seen);

        next.HasChanged(file).Should().BeFalse();
        hashed.Should().BeEmpty();
        next.Seen[file].Should().Be(first.Seen[file]);
    }

    [Fact]
    public void A_file_touched_but_not_changed_is_hashed_once_and_has_not_changed()
    {
        string file = temp.Write("a.txt", "one");
        FileTracker first = Next();
        first.HasChanged(file);
        File.SetLastWriteTimeUtc(file, DateTime.UtcNow.AddMinutes(10));
        hashed.Clear();

        FileTracker second = Next(first.Seen);
        second.HasChanged(file).Should().BeFalse();
        hashed.Should().Equal(file);

        // The new mtime is what the run after compares with: no hash then.
        hashed.Clear();
        Next(second.Seen).HasChanged(file).Should().BeFalse();
        hashed.Should().BeEmpty();
    }

    [Fact]
    public void A_changed_file_has_changed()
    {
        string file = temp.Write("a.txt", "one");
        FileTracker first = Next();
        first.HasChanged(file);
        File.WriteAllText(file, "two");
        File.SetLastWriteTimeUtc(file, DateTime.UtcNow.AddMinutes(10));

        Next(first.Seen).HasChanged(file).Should().BeTrue();
    }

    [Fact]
    public void A_file_that_is_gone_has_changed_and_is_not_seen()
    {
        string file = temp.Write("a.txt", "one");
        FileTracker first = Next();
        first.HasChanged(file);
        File.Delete(file);

        FileTracker next = Next(first.Seen);

        next.HasChanged(file).Should().BeTrue();
        next.Seen.Should().NotContainKey(file);
    }

    [Fact]
    public void A_run_sees_only_the_files_it_looked_at_and_leaves_what_the_last_run_saw_alone()
    {
        string kept = temp.Write("kept.txt", "x");
        string dropped = temp.Write("dropped.txt", "x");
        FileTracker first = Next();
        first.HasChanged(kept);
        first.HasChanged(dropped);

        FileTracker next = Next(first.Seen);
        next.HasChanged(kept);

        next.Seen.Keys.Should().Equal(kept);
        next.Known.Should().HaveCount(2);
    }

    [Fact]
    public void Paths_compare_as_the_platform_compares_them()
    {
        string file = temp.Write("Notes.md", "x");
        FileTracker first = Next();
        first.HasChanged(file);

        string otherCase = Path.Combine(temp.Path, "NOTES.MD");
        first.Seen.ContainsKey(otherCase).Should().Be(OperatingSystem.IsWindows());
    }

    [Fact]
    public void A_path_that_is_not_full_is_refused()
    {
        Action check = () => Next().HasChanged("a.txt");

        check.Should().Throw<ArgumentException>();
    }
}
