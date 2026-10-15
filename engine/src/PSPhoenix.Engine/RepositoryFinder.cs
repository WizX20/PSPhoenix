namespace PSPhoenix.Engine;

/// <summary>
/// Repository discovery (docs/design.md -> Concepts): the repositories under one root, breadth-first
/// to a depth - a repository directly in the root is depth 1. A folder with a <c>.git</c> folder is a
/// repository: found, not entered. A <c>.git</c> file marks a linked worktree or a submodule:
/// skipped - a worktree belongs to its main repository, a submodule comes back with its parent.
/// Links and junctions are not followed; a cloud-sync placeholder (OneDrive, Dropbox) is a reparse
/// point without a link target and is searched like any folder. Build output and package caches are
/// not entered. A folder that cannot be read, or vanishes during the walk, is passed over.
/// </summary>
public static class RepositoryFinder
{
    /// <summary>Folders never entered: they hold thousands of folders and no repository worth finding.</summary>
    public static IReadOnlyList<string> Skipped { get; } =
    [
        "node_modules", "bin", "obj", "packages", ".vs", ".idea", ".venv", "venv", "__pycache__", ".gradle",
        ".dart_tool", ".terraform", ".next", "$RECYCLE.BIN", "System Volume Information",
    ];

    private static readonly HashSet<string> Skip = new(Skipped, StringComparer.OrdinalIgnoreCase);

    /// <summary>The repositories under <paramref name="root"/>, to <paramref name="depth"/> levels; the root itself when it is one.</summary>
    public static IReadOnlyList<string> Find(string root, int depth)
    {
        AtomicFile.RequireFullPath(root);
        if (Directory.Exists(Path.Combine(root, ".git")))
        {
            return [root];
        }
        List<string> found = [];
        Queue<(string Folder, int Level)> queue = new();
        queue.Enqueue((root, 0));
        while (queue.Count > 0)
        {
            (string folder, int level) = queue.Dequeue();
            if (level >= depth)
            {
                continue;
            }
            string[] children;
            try
            {
                children = Directory.GetDirectories(folder);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (string child in children)
            {
                try
                {
                    if (Skip.Contains(Path.GetFileName(child)) || IsLink(child))
                    {
                        continue;
                    }
                    string git = Path.Combine(child, ".git");
                    if (Directory.Exists(git))
                    {
                        found.Add(child);
                    }
                    else if (!File.Exists(git))
                    {
                        queue.Enqueue((child, level + 1));
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    // Gone or unreadable while the walk looked at it.
                }
            }
        }
        return found;
    }

    // A junction or symbolic link - not a cloud-sync placeholder, which has no link target.
    private static bool IsLink(string folder)
    {
        DirectoryInfo info = new(folder);
        return info.Attributes.HasFlag(FileAttributes.ReparsePoint) && info.LinkTarget is not null;
    }
}
