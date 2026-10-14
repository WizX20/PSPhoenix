using System.Diagnostics;
using System.Security.Cryptography;

namespace PSPhoenix.Engine.Tests;

/// <summary>
/// The engine's age against the age tool itself, both ways - so a snapshot opens with age when
/// PSPhoenix is gone. Runs where age and age-keygen are on PATH (CI installs them on Linux);
/// elsewhere it is skipped. Passphrases are left to the test vectors: age reads one only from a
/// terminal.
/// </summary>
public sealed class AgeInteropTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    [Fact]
    public void The_age_tool_decrypts_what_the_engine_encrypts()
    {
        SkipWithoutAge();
        AgeKey key = Age.NewKey();
        File.WriteAllText(temp["key.txt"], key.Identity + "\n");
        byte[] plaintext = RandomNumberGenerator.GetBytes(200_000);
        File.WriteAllBytes(temp["secret.age"], Age.Encrypt(plaintext, key.Recipient));

        Run("age", "--decrypt", "--identity", temp["key.txt"], "--output", temp["secret.txt"], temp["secret.age"]);

        File.ReadAllBytes(temp["secret.txt"]).Should().Equal(plaintext);
    }

    [Fact]
    public void The_engine_decrypts_what_the_age_tool_encrypts_and_reads_its_keys()
    {
        SkipWithoutAge();
        Run("age-keygen", "--output", temp["key.txt"]);
        string identity = File.ReadAllLines(temp["key.txt"]).Single(line => line.StartsWith("AGE-SECRET-KEY-1", StringComparison.Ordinal));
        string recipient = Run("age-keygen", "-y", temp["key.txt"]).Trim();
        Age.RecipientOf(identity).Should().Be(recipient);
        byte[] plaintext = RandomNumberGenerator.GetBytes(3 * 64 * 1024);
        File.WriteAllBytes(temp["secret.txt"], plaintext);

        Run("age", "--encrypt", "--recipient", recipient, "--output", temp["secret.age"], temp["secret.txt"]);

        Age.Decrypt(File.ReadAllBytes(temp["secret.age"]), identity).Should().Equal(plaintext);
    }

    [Fact]
    public void The_age_tool_opens_a_passphrase_file_and_a_passphrase_protected_key_file()
    {
        // What a restore without PSPhoenix comes down to: age -d -i key.age, typing the passphrase.
        SkipWithoutAge();
        Assert.SkipUnless(OperatingSystem.IsLinux() && OnPath("script"), "age reads a passphrase only from a terminal: script(1) gives it one, on Linux");
        const string passphrase = "correct horse battery staple";
        byte[] plaintext = RandomNumberGenerator.GetBytes(1000);
        File.WriteAllBytes(temp["secret.age"], Age.EncryptWithPassphrase(plaintext, passphrase, workFactor: 10));
        AgeKey key = Age.NewKey();
        File.WriteAllBytes(temp["key.age"], Age.EncryptWithPassphrase(System.Text.Encoding.UTF8.GetBytes($"# public key: {key.Recipient}\n{key.Identity}\n"), passphrase, workFactor: 10));
        File.WriteAllBytes(temp["file.age"], Age.Encrypt(plaintext, key.Recipient));

        RunInTerminal(passphrase, $"age --decrypt --output '{temp["secret.txt"]}' '{temp["secret.age"]}'");
        RunInTerminal(passphrase, $"age --decrypt --identity '{temp["key.age"]}' --output '{temp["file.txt"]}' '{temp["file.age"]}'");

        File.ReadAllBytes(temp["secret.txt"]).Should().Equal(plaintext);
        File.ReadAllBytes(temp["file.txt"]).Should().Equal(plaintext);
    }

    /// <summary>Runs a shell command in a pseudo-terminal (script -qec), typing <paramref name="typed"/> into it.</summary>
    private static void RunInTerminal(string typed, string command)
    {
        ProcessStartInfo start = new("script") { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in new[] { "-qec", command, "/dev/null" })
        {
            start.ArgumentList.Add(argument);
        }
        using Process process = Process.Start(start)!;
        process.StandardInput.Write(typed + "\n");
        process.StandardInput.Flush();
        string output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        process.WaitForExit();
        process.ExitCode.Should().Be(0, $"`{command}` said: {output.Replace(typed, "***", StringComparison.Ordinal)}");
    }

    private static void SkipWithoutAge()
        => Assert.SkipUnless(OnPath("age") && OnPath("age-keygen"), "the age tool is not installed (CI installs it on Linux)");

    private static bool OnPath(string tool)
    {
        string[] names = OperatingSystem.IsWindows() ? [tool + ".exe"] : [tool];
        return (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Any(folder => names.Any(name => File.Exists(Path.Combine(folder, name))));
    }

    private static string Run(string tool, params string[] arguments)
    {
        ProcessStartInfo start = new(tool) { RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using Process process = Process.Start(start)!;
        string output = process.StandardOutput.ReadToEnd();
        string error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        process.ExitCode.Should().Be(0, $"{tool} said: {error}");
        return output;
    }
}
