namespace PSPhoenix.Engine.Tests;

public sealed class FileHashTests : IDisposable
{
    private readonly TempFolder temp = new();

    public void Dispose() => temp.Dispose();

    [Fact]
    public void Sha256_is_the_upper_case_hex_of_the_content()
    {
        string path = temp.Write("abc.txt", "abc");

        FileHash.Sha256(path).Should().Be("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD");
    }

    [Fact]
    public void Sha256_of_an_empty_file()
    {
        string path = temp.Write("empty.txt", "");

        FileHash.Sha256(path).Should().Be("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855");
    }

    [Fact]
    public void Sha256_reads_a_file_another_program_is_writing()
    {
        string path = temp.Write("busy.txt", "abc");
        using FileStream writer = new(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);

        FileHash.Sha256(path).Should().Be("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD");
    }

    [Fact]
    public void Sha256_of_a_missing_file_throws()
    {
        Action hash = () => FileHash.Sha256(temp["missing.txt"]);

        hash.Should().Throw<FileNotFoundException>();
    }

    [Fact]
    public void Sha256Text_hashes_the_utf8_bytes()
    {
        FileHash.Sha256Text("abc").Should().Be("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD");
        FileHash.Sha256Text("ë").Should().Be(FileHash.Sha256(temp.Write("e.txt", "ë")));
    }
}
