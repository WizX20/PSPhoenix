namespace PSPhoenix.Engine.Tests;

/// <summary>A scratch folder per test, removed afterwards - the engine's $TestDrive.</summary>
public sealed class TempFolder : IDisposable
{
    public TempFolder()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "phx-engine-" + Guid.NewGuid().ToString("N")[..12]);
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    /// <summary>A full path inside the folder; the parts are joined with the platform's separator.</summary>
    public string this[params string[] parts] => System.IO.Path.Combine([Path, .. parts]);

    /// <summary>Writes a file (its folder created) and returns its full path.</summary>
    public string Write(string relative, string content)
    {
        string path = System.IO.Path.Combine(Path, relative);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
            // A file still held open by a failed test: the temp folder gets cleaned up eventually.
        }
    }
}
