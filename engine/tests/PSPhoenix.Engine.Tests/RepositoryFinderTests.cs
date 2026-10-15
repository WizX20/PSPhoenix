namespace PSPhoenix.Engine.Tests;

public sealed class RepositoryFinderTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private string Repo(params string[] parts)
    {
        string path = temp[parts];
        Directory.CreateDirectory(Path.Combine(path, ".git"));
        return path;
    }

    [Fact]
    public void Finds_repositories_to_the_depth_and_does_not_enter_them()
    {
        string one = Repo("One");
        string deep = Repo("org", "team", "Deep");
        Repo("org", "team", "group", "TooDeep");
        Repo("One", "nested", "Inner");

        RepositoryFinder.Find(temp.Path, 3).Should().BeEquivalentTo([one, deep]);
    }

    [Fact]
    public void A_root_that_is_a_repository_is_the_only_one()
    {
        string root = Repo("Root");
        Repo("Root", "Child");

        RepositoryFinder.Find(root, 3).Should().Equal(root);
    }

    [Fact]
    public void Skips_worktrees_submodules_and_build_folders()
    {
        temp.Write(Path.Combine("Worktree", ".git"), "gitdir: elsewhere");
        Repo("node_modules", "pkg");
        Repo("Bin", "Hidden");
        string real = Repo("src", "Real");

        RepositoryFinder.Find(temp.Path, 3).Should().Equal(real);
    }

    [Fact]
    public void Does_not_follow_a_link()
    {
        string real = Repo("outside", "Repo");
        string root = temp["root"];
        Directory.CreateDirectory(root);
        try
        {
            Directory.CreateSymbolicLink(Path.Combine(root, "linked"), Path.GetDirectoryName(real)!);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Assert.Skip("this account cannot create symbolic links");
        }

        RepositoryFinder.Find(root, 3).Should().BeEmpty();
    }

    [Fact]
    public void An_empty_or_missing_root_finds_nothing()
    {
        RepositoryFinder.Find(temp["missing"], 3).Should().BeEmpty();
        RepositoryFinder.Find(temp.Path, 3).Should().BeEmpty();
    }
}
