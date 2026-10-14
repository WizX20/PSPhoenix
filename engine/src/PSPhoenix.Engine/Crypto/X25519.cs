namespace PSPhoenix.Engine.Crypto;

/// <summary>
/// X25519 (RFC 7748): Diffie-Hellman on Curve25519, as age uses it. .NET has no Curve25519, so this
/// is a port of TweetNaCl's <c>crypto_scalarmult</c> (public domain, Bernstein et al.): field
/// elements as 16 limbs of 16 bits, a Montgomery ladder with constant-time swaps, no branches on
/// secret data. Tested against RFC 7748 and the age test vectors.
/// </summary>
internal static class X25519
{
    /// <summary>The size of a scalar, a point and a shared secret.</summary>
    public const int Size = 32;

    private static readonly long[] A24 = [0xDB41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

    /// <summary>The base point, u = 9.</summary>
    private static readonly byte[] BasePoint = [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

    /// <summary>The public key of <paramref name="scalar"/>: its product with the base point.</summary>
    public static byte[] PublicKey(ReadOnlySpan<byte> scalar) => ScalarMult(scalar, BasePoint);

    /// <summary><paramref name="scalar"/> times the point <paramref name="point"/>, both 32 bytes, the scalar clamped.</summary>
    public static byte[] ScalarMult(ReadOnlySpan<byte> scalar, ReadOnlySpan<byte> point)
    {
        if (scalar.Length != Size || point.Length != Size)
        {
            throw new ArgumentException("X25519 takes a 32-byte scalar and a 32-byte point");
        }
        byte[] z = scalar.ToArray();
        z[31] = (byte)((z[31] & 127) | 64);
        z[0] &= 248;
        long[] x = new long[16];
        Unpack(x, point);
        long[] a = new long[16], b = new long[16], c = new long[16], d = new long[16], e = new long[16], f = new long[16];
        Array.Copy(x, b, 16);
        a[0] = d[0] = 1;
        for (int i = 254; i >= 0; i--)
        {
            long bit = (z[i >> 3] >> (i & 7)) & 1;
            Swap(a, b, bit);
            Swap(c, d, bit);
            Add(e, a, c);
            Sub(a, a, c);
            Add(c, b, d);
            Sub(b, b, d);
            Mul(d, e, e);
            Mul(f, a, a);
            Mul(a, c, a);
            Mul(c, b, e);
            Add(e, a, c);
            Sub(a, a, c);
            Mul(b, a, a);
            Sub(c, d, f);
            Mul(a, c, A24);
            Add(a, a, d);
            Mul(c, c, a);
            Mul(a, d, f);
            Mul(d, b, x);
            Mul(b, e, e);
            Swap(a, b, bit);
            Swap(c, d, bit);
        }
        Invert(c, c);
        Mul(a, a, c);
        byte[] result = new byte[Size];
        Pack(result, a);
        foreach (long[] limbs in new[] { x, a, b, c, d, e, f })
        {
            Array.Clear(limbs);
        }
        Array.Clear(z);
        return result;
    }

    private static void Carry(long[] o)
    {
        for (int i = 0; i < 16; i++)
        {
            o[i] += 1L << 16;
            long c = o[i] >> 16;
            if (i < 15)
            {
                o[i + 1] += c - 1;
            }
            else
            {
                o[0] += 38 * (c - 1);
            }
            o[i] -= c << 16;
        }
    }

    /// <summary>Swaps p and q when bit is 1, without a branch.</summary>
    private static void Swap(long[] p, long[] q, long bit)
    {
        long mask = ~(bit - 1);
        for (int i = 0; i < 16; i++)
        {
            long t = mask & (p[i] ^ q[i]);
            p[i] ^= t;
            q[i] ^= t;
        }
    }

    private static void Pack(byte[] o, long[] n)
    {
        long[] m = new long[16];
        long[] t = (long[])n.Clone();
        Carry(t);
        Carry(t);
        Carry(t);
        for (int j = 0; j < 2; j++)
        {
            m[0] = t[0] - 0xffed;
            for (int i = 1; i < 15; i++)
            {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
                m[i - 1] &= 0xffff;
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
            long borrow = (m[15] >> 16) & 1;
            m[14] &= 0xffff;
            Swap(t, m, 1 - borrow);
        }
        for (int i = 0; i < 16; i++)
        {
            o[2 * i] = (byte)(t[i] & 0xff);
            o[(2 * i) + 1] = (byte)(t[i] >> 8);
        }
    }

    private static void Unpack(long[] o, ReadOnlySpan<byte> n)
    {
        for (int i = 0; i < 16; i++)
        {
            o[i] = n[2 * i] + ((long)n[(2 * i) + 1] << 8);
        }
        o[15] &= 0x7fff;
    }

    private static void Add(long[] o, long[] a, long[] b)
    {
        for (int i = 0; i < 16; i++)
        {
            o[i] = a[i] + b[i];
        }
    }

    private static void Sub(long[] o, long[] a, long[] b)
    {
        for (int i = 0; i < 16; i++)
        {
            o[i] = a[i] - b[i];
        }
    }

    private static void Mul(long[] o, long[] a, long[] b)
    {
        Span<long> t = stackalloc long[31];
        for (int i = 0; i < 16; i++)
        {
            for (int j = 0; j < 16; j++)
            {
                t[i + j] += a[i] * b[j];
            }
        }
        for (int i = 0; i < 15; i++)
        {
            t[i] += 38 * t[i + 16];
        }
        for (int i = 0; i < 16; i++)
        {
            o[i] = t[i];
        }
        Carry(o);
        Carry(o);
    }

    /// <summary>The inverse modulo 2^255 - 19, as a power: i^(p-2).</summary>
    private static void Invert(long[] o, long[] i)
    {
        long[] c = (long[])i.Clone();
        for (int a = 253; a >= 0; a--)
        {
            Mul(c, c, c);
            if (a != 2 && a != 4)
            {
                Mul(c, c, i);
            }
        }
        Array.Copy(c, o, 16);
    }
}
