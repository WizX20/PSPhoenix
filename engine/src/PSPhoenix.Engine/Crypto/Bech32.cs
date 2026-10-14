using System.Text;

namespace PSPhoenix.Engine.Crypto;

/// <summary>
/// Bech32 (BIP 173), as age writes its keys: <c>age1…</c> for a recipient,
/// <c>AGE-SECRET-KEY-1…</c> for an identity. Like age it has no 90-character limit, and it refuses
/// mixed case.
/// </summary>
internal static class Bech32
{
    private const string Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    private static readonly uint[] Generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

    /// <summary>Encodes <paramref name="data"/> under the human-readable part <paramref name="hrp"/>, in lower case.</summary>
    public static string Encode(string hrp, ReadOnlySpan<byte> data)
    {
        hrp = hrp.ToLowerInvariant();
        byte[] values = ConvertBits(data, 8, 5, pad: true) ?? throw new ArgumentException("cannot convert the data", nameof(data));
        byte[] checksum = Checksum(hrp, values);
        StringBuilder text = new(hrp.Length + 1 + values.Length + checksum.Length);
        text.Append(hrp).Append('1');
        foreach (byte value in values)
        {
            text.Append(Charset[value]);
        }
        foreach (byte value in checksum)
        {
            text.Append(Charset[value]);
        }
        return text.ToString();
    }

    /// <summary>The human-readable part (in lower case) and the data of <paramref name="text"/>; null when it is not valid Bech32.</summary>
    public static (string Hrp, byte[] Data)? Decode(string text)
    {
        if (text.Length < 8 || (text.Any(char.IsLower) && text.Any(char.IsUpper)) || text.Any(c => c < 33 || c > 126))
        {
            return null;
        }
        string lower = text.ToLowerInvariant();
        int separator = lower.LastIndexOf('1');
        if (separator < 1 || separator + 7 > lower.Length)
        {
            return null;
        }
        string hrp = lower[..separator];
        byte[] values = new byte[lower.Length - separator - 1];
        for (int i = 0; i < values.Length; i++)
        {
            int index = Charset.IndexOf(lower[separator + 1 + i], StringComparison.Ordinal);
            if (index < 0)
            {
                return null;
            }
            values[i] = (byte)index;
        }
        if (Polymod([.. ExpandHrp(hrp), .. values]) != 1)
        {
            return null;
        }
        byte[]? data = ConvertBits(values.AsSpan(0, values.Length - 6), 5, 8, pad: false);
        return data is null ? null : (hrp, data);
    }

    private static uint Polymod(ReadOnlySpan<byte> values)
    {
        uint checksum = 1;
        foreach (byte value in values)
        {
            uint top = checksum >> 25;
            checksum = ((checksum & 0x1ffffff) << 5) ^ value;
            for (int i = 0; i < 5; i++)
            {
                if (((top >> i) & 1) != 0)
                {
                    checksum ^= Generator[i];
                }
            }
        }
        return checksum;
    }

    private static byte[] ExpandHrp(string hrp)
    {
        byte[] expanded = new byte[(hrp.Length * 2) + 1];
        for (int i = 0; i < hrp.Length; i++)
        {
            expanded[i] = (byte)(hrp[i] >> 5);
            expanded[i + hrp.Length + 1] = (byte)(hrp[i] & 31);
        }
        return expanded;
    }

    private static byte[] Checksum(string hrp, byte[] values)
    {
        uint polymod = Polymod([.. ExpandHrp(hrp), .. values, 0, 0, 0, 0, 0, 0]) ^ 1;
        byte[] checksum = new byte[6];
        for (int i = 0; i < 6; i++)
        {
            checksum[i] = (byte)((polymod >> (5 * (5 - i))) & 31);
        }
        return checksum;
    }

    /// <summary>Regroups bits; null when the input does not fit (leftover bits that are not zero, or too many).</summary>
    private static byte[]? ConvertBits(ReadOnlySpan<byte> data, int from, int to, bool pad)
    {
        int accumulator = 0;
        int bits = 0;
        int max = (1 << to) - 1;
        List<byte> result = new((data.Length * from / to) + 1);
        foreach (byte value in data)
        {
            if (value >> from != 0)
            {
                return null;
            }
            accumulator = (accumulator << from) | value;
            bits += from;
            while (bits >= to)
            {
                bits -= to;
                result.Add((byte)((accumulator >> bits) & max));
            }
        }
        if (pad)
        {
            if (bits > 0)
            {
                result.Add((byte)((accumulator << (to - bits)) & max));
            }
        }
        else if (bits >= from || ((accumulator << (to - bits)) & max) != 0)
        {
            return null;
        }
        return [.. result];
    }
}
