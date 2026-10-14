using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace PSPhoenix.Engine.Tests;

public sealed class AgeTests
{
    private static readonly AgeKey Key = Age.NewKey();

    [Fact]
    public void A_new_key_pair_is_an_identity_and_its_recipient()
    {
        AgeKey key = Age.NewKey();

        key.Identity.Should().MatchRegex("^AGE-SECRET-KEY-1[QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L]{58}$");
        key.Recipient.Should().MatchRegex("^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$");
        Age.RecipientOf(key.Identity).Should().Be(key.Recipient);
        Age.IsIdentity(key.Identity).Should().BeTrue();
        Age.IsRecipient(key.Recipient).Should().BeTrue();
        Age.NewKey().Identity.Should().NotBe(key.Identity);
        key.ToString().Should().Be(key.Recipient, "a key pair prints without its secret half");
    }

    [Theory]
    [InlineData("")]
    [InlineData("age1")]
    [InlineData("AGE1QYQSZQGPQYQSZQGPQYQSZQGPQYQSZQGPQYQSZQGPQYQSZQGPQYQS3290GQ")]
    [InlineData("age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gr")]
    [InlineData("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")]
    public void Refuses_what_is_not_a_recipient(string text)
        => Age.IsRecipient(text).Should().BeFalse();

    [Theory]
    [InlineData("0000000000000000000000000000000000000000000000000000000000000000")]
    [InlineData("0100000000000000000000000000000000000000000000000000000000000000")]
    [InlineData("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")]
    [InlineData("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157")]
    [InlineData("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")]
    public void Refuses_a_low_order_point_as_recipient(string point)
    {
        // Encrypting to one makes the shared secret zero, and so the file key public.
        string recipient = PSPhoenix.Engine.Crypto.Bech32.Encode("age", Convert.FromHexString(point));

        Age.IsRecipient(recipient).Should().BeFalse();
        ((Action)(() => Age.Encrypt([1], recipient))).Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Takes_keys_only_in_the_case_age_writes_them()
    {
        Age.IsIdentity(Key.Identity.ToLowerInvariant()).Should().BeFalse();
        Age.IsRecipient(Key.Recipient.ToUpperInvariant()).Should().BeFalse();
        ((Action)(() => Age.Decrypt([1], Key.Identity.ToLowerInvariant()))).Should().Throw<ArgumentException>();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(64 * 1024 - 1)]
    [InlineData(64 * 1024)]
    [InlineData(64 * 1024 + 1)]
    [InlineData(3 * 64 * 1024)]
    public void Encrypts_to_a_recipient_and_decrypts_with_the_identity(int size)
    {
        byte[] plaintext = RandomNumberGenerator.GetBytes(size);

        byte[] file = Age.Encrypt(plaintext, Key.Recipient);

        Encoding.ASCII.GetString(file, 0, 22).Should().Be("age-encryption.org/v1\n");
        Age.Decrypt(file, Key.Identity).Should().Equal(plaintext);
    }

    [Fact]
    public void Encrypting_twice_gives_two_different_files()
    {
        byte[] plaintext = Encoding.UTF8.GetBytes("Password=Winter2024!");

        Age.Encrypt(plaintext, Key.Recipient).Should().NotEqual(Age.Encrypt(plaintext, Key.Recipient));
    }

    [Fact]
    public void Another_identity_finds_no_match()
    {
        byte[] file = Age.Encrypt([1, 2, 3], Key.Recipient);

        Action decrypt = () => Age.Decrypt(file, Age.NewKey().Identity);

        decrypt.Should().Throw<AgeException>().Which.Failure.Should().Be(AgeFailure.NoMatch);
    }

    [Fact]
    public void A_changed_payload_fails_and_a_changed_header_fails_its_mac()
    {
        byte[] file = Age.Encrypt(Encoding.UTF8.GetBytes("secret"), Key.Recipient);
        byte[] payload = (byte[])file.Clone();
        payload[^1] ^= 1;
        int at = Encoding.ASCII.GetString(file).IndexOf("\n---", StringComparison.Ordinal);
        byte[] grease = [.. file.AsSpan(0, at + 1), .. "-> grease\n\n"u8, .. file.AsSpan(at + 1)];

        ((Action)(() => Age.Decrypt(payload, Key.Identity))).Should().Throw<AgeException>().Which.Failure.Should().Be(AgeFailure.Payload);
        ((Action)(() => Age.Decrypt(grease, Key.Identity))).Should().Throw<AgeException>().Which.Failure.Should().Be(AgeFailure.Hmac);
        Age.Decrypt(file, Key.Identity).Should().Equal(Encoding.UTF8.GetBytes("secret"));
    }

    [Fact]
    public void Encrypts_with_a_passphrase_and_decrypts_with_it()
    {
        byte[] plaintext = Encoding.UTF8.GetBytes(Key.Identity);

        byte[] file = Age.EncryptWithPassphrase(plaintext, "correct horse battery staple", workFactor: 10);

        Encoding.ASCII.GetString(file).Should().Contain("\n-> scrypt ").And.Contain(" 10\n");
        Age.DecryptWithPassphrase(file, "correct horse battery staple").Should().Equal(plaintext);
        ((Action)(() => Age.DecryptWithPassphrase(file, "wrong horse"))).Should().Throw<AgeException>().Which.Failure.Should().Be(AgeFailure.NoMatch);
        ((Action)(() => Age.DecryptWithPassphrase(file, "correct horse battery staple", maxWorkFactor: 9))).Should().Throw<AgeException>().Which.Failure.Should().Be(AgeFailure.Header);
    }

    [Fact]
    public void Refuses_bad_arguments()
    {
        ((Action)(() => Age.Encrypt([1], "age1nope"))).Should().Throw<ArgumentException>();
        ((Action)(() => Age.Decrypt([1], Key.Recipient))).Should().Throw<ArgumentException>();
        ((Action)(() => Age.EncryptWithPassphrase([1], ""))).Should().Throw<ArgumentException>();
        ((Action)(() => Age.EncryptWithPassphrase([1], "long enough", workFactor: Age.MaxWorkFactor + 1))).Should().Throw<ArgumentOutOfRangeException>();
        ((Action)(() => Age.Decrypt("not an age file\n"u8.ToArray(), Key.Identity))).Should().Throw<AgeException>().Which.Failure.Should().Be(AgeFailure.Header);
    }

    /// <summary>The official age test vectors (C2SP CCTV, see testkit/README.md), minus armor and hybrid keys.</summary>
    public static TheoryData<string> Vectors()
    {
        TheoryData<string> names = [];
        foreach (string path in Directory.EnumerateFiles(Path.Combine(AppContext.BaseDirectory, "testkit")).Order(StringComparer.Ordinal))
        {
            string name = Path.GetFileName(path);
            if (name is not ("LICENSE" or "README.md"))
            {
                names.Add(name);
            }
        }
        return names;
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void Passes_the_age_test_vector(string name)
    {
        Vector vector = Vector.Read(Path.Combine(AppContext.BaseDirectory, "testkit", name));
        Assert.SkipWhen(vector.Armored, "the ASCII armor is not built: PSPhoenix writes binary age files");
        Assert.SkipWhen(vector.Identities.Any(i => i.StartsWith("AGE-SECRET-KEY-PQ-", StringComparison.Ordinal)), "hybrid post-quantum keys are not built");

        // Every key the vector names gets its turn; a vector without one is opened with an unrelated key.
        List<(string Key, Func<byte[]> Decrypt)> attempts =
        [
            .. vector.Passphrases.Select(p => (p, (Func<byte[]>)(() => Age.DecryptWithPassphrase(vector.File, p)))),
            .. vector.Identities.Select(i => (i, (Func<byte[]>)(() => Age.Decrypt(vector.File, i)))),
        ];
        if (attempts.Count == 0)
        {
            attempts.Add(("(none)", () => Age.Decrypt(vector.File, Key.Identity)));
        }
        foreach ((string key, Func<byte[]> decrypt) in attempts)
        {
            string because = $"{name} with {key[..Math.Min(key.Length, 20)]}";
            if (vector.Expect == "success")
            {
                Convert.ToHexString(SHA256.HashData(decrypt())).Should().BeEquivalentTo(vector.Payload, because);
                continue;
            }
            AgeException failure = decrypt.Should().Throw<AgeException>(because).Which;
            failure.Failure.Should().Be(vector.Expect switch
            {
                "header failure" => AgeFailure.Header,
                "no match" => AgeFailure.NoMatch,
                "HMAC failure" => AgeFailure.Hmac,
                "payload failure" => AgeFailure.Payload,
                _ => throw new InvalidOperationException($"unknown expectation '{vector.Expect}'"),
            }, $"{because}: {failure.Message}");
            if (vector.Expect == "payload failure")
            {
                // What decrypted before the failure is what a reader would have been handed.
                Convert.ToHexString(SHA256.HashData(failure.Released)).Should().BeEquivalentTo(vector.Payload, because);
            }
        }
    }

    private sealed record Vector(string Expect, string? Payload, List<string> Identities, List<string> Passphrases, bool Armored, byte[] File)
    {
        public static Vector Read(string path)
        {
            byte[] bytes = System.IO.File.ReadAllBytes(path);
            int split = bytes.AsSpan().IndexOf("\n\n"u8);
            string[] lines = Encoding.UTF8.GetString(bytes, 0, split).Split('\n');
            Dictionary<string, List<string>> fields = [];
            foreach (string line in lines)
            {
                int colon = line.IndexOf(": ", StringComparison.Ordinal);
                string key = line[..colon];
                if (!fields.TryGetValue(key, out List<string>? values))
                {
                    fields[key] = values = [];
                }
                values.Add(line[(colon + 2)..]);
            }
            byte[] file = bytes[(split + 2)..];
            if (fields.ContainsKey("compressed"))
            {
                using ZLibStream zlib = new(new MemoryStream(file), CompressionMode.Decompress);
                using MemoryStream inflated = new();
                zlib.CopyTo(inflated);
                file = inflated.ToArray();
            }
            return new Vector(
                fields["expect"][0],
                fields.GetValueOrDefault("payload")?[0],
                fields.GetValueOrDefault("identity") ?? [],
                fields.GetValueOrDefault("passphrase") ?? [],
                fields.GetValueOrDefault("armored")?[0] == "yes",
                file);
        }
    }
}
