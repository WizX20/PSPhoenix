using System.Text;
using PSPhoenix.Engine.Crypto;

namespace PSPhoenix.Engine.Tests;

public sealed class CryptoTests
{
    [Theory]
    // RFC 7748, 5.2.
    [InlineData("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4", "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c", "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")]
    [InlineData("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d", "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493", "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957")]
    public void X25519_matches_rfc_7748(string scalar, string point, string expected)
        => Convert.ToHexString(X25519.ScalarMult(Convert.FromHexString(scalar), Convert.FromHexString(point))).Should().BeEquivalentTo(expected);

    [Fact]
    public void X25519_agrees_on_the_rfc_7748_shared_secret()
    {
        byte[] alice = Convert.FromHexString("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
        byte[] bob = Convert.FromHexString("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");

        Convert.ToHexString(X25519.PublicKey(alice)).Should().BeEquivalentTo("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
        Convert.ToHexString(X25519.PublicKey(bob)).Should().BeEquivalentTo("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
        string shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
        Convert.ToHexString(X25519.ScalarMult(alice, X25519.PublicKey(bob))).Should().BeEquivalentTo(shared);
        Convert.ToHexString(X25519.ScalarMult(bob, X25519.PublicKey(alice))).Should().BeEquivalentTo(shared);
    }

    [Fact]
    public void X25519_iterates_as_rfc_7748_says()
    {
        byte[] k = new byte[32];
        k[0] = 9;
        byte[] u = (byte[])k.Clone();
        for (int i = 1; i <= 1000; i++)
        {
            byte[] next = X25519.ScalarMult(k, u);
            u = k;
            k = next;
            if (i == 1)
            {
                Convert.ToHexString(k).Should().BeEquivalentTo("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079");
            }
        }
        Convert.ToHexString(k).Should().BeEquivalentTo("684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51");
    }

    [Fact]
    public void Scrypt_matches_rfc_7914()
    {
        Convert.ToHexString(Scrypt.DeriveKey([], [], 4, 1, 1, 64)).Should().BeEquivalentTo(
            "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906");
        Convert.ToHexString(Scrypt.DeriveKey(Encoding.ASCII.GetBytes("password"), Encoding.ASCII.GetBytes("NaCl"), 10, 8, 16, 64)).Should().BeEquivalentTo(
            "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640");
    }

    [Fact]
    public void Bech32_round_trips_and_refuses_what_is_broken()
    {
        byte[] data = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();

        string text = Bech32.Encode("age", data);

        text.Should().StartWith("age1");
        Bech32.Decode(text).Should().NotBeNull();
        Bech32.Decode(text)!.Value.Data.Should().Equal(data);
        Bech32.Decode(text.ToUpperInvariant())!.Value.Hrp.Should().Be("age");
        Bech32.Decode(text[..^1] + (text[^1] == 'q' ? 'p' : 'q')).Should().BeNull("the checksum is wrong");
        Bech32.Decode("age1" + char.ToUpperInvariant(text[4]) + text[5..]).Should().BeNull("mixed case");
        Bech32.Decode(text.Replace('q', 'b')).Should().BeNull("b is not in the alphabet");
    }
}
