using System.Buffers.Binary;
using System.Numerics;
using System.Security.Cryptography;

namespace PSPhoenix.Engine.Crypto;

/// <summary>
/// scrypt (RFC 7914), the key derivation behind an age passphrase. .NET has PBKDF2 but no scrypt;
/// this is the RFC's algorithm on top of it - BlockMix with Salsa20/8, then ROMix - tested against
/// the RFC's vectors and the age test vectors.
/// </summary>
internal static class Scrypt
{
    /// <summary>The key of <paramref name="length"/> bytes for a password and a salt, with cost N = 2^<paramref name="logN"/>.</summary>
    public static byte[] DeriveKey(byte[] password, byte[] salt, int logN, int r, int p, int length)
    {
        if (logN is < 1 or > 30 || r < 1 || p < 1 || (long)32 * r << logN > Array.MaxLength)
        {
            throw new ArgumentOutOfRangeException(nameof(logN), "scrypt parameters out of range");
        }
        int n = 1 << logN;
        int blockWords = 32 * r;
        byte[] b = Rfc2898DeriveBytes.Pbkdf2(password, salt, 1, HashAlgorithmName.SHA256, p * 128 * r);
        uint[] x = new uint[blockWords];
        uint[] y = new uint[blockWords];
        uint[] v = new uint[blockWords * n];
        for (int i = 0; i < p; i++)
        {
            Span<byte> chunk = b.AsSpan(i * 128 * r, 128 * r);
            for (int k = 0; k < blockWords; k++)
            {
                x[k] = BinaryPrimitives.ReadUInt32LittleEndian(chunk[(4 * k)..]);
            }
            for (int j = 0; j < n; j++)
            {
                Array.Copy(x, 0, v, j * blockWords, blockWords);
                BlockMix(x, y, r);
            }
            for (int j = 0; j < n; j++)
            {
                int index = (int)(x[(2 * r - 1) * 16] & (uint)(n - 1));
                for (int k = 0; k < blockWords; k++)
                {
                    x[k] ^= v[(index * blockWords) + k];
                }
                BlockMix(x, y, r);
            }
            for (int k = 0; k < blockWords; k++)
            {
                BinaryPrimitives.WriteUInt32LittleEndian(chunk[(4 * k)..], x[k]);
            }
        }
        Array.Clear(v);
        Array.Clear(x);
        Array.Clear(y);
        try
        {
            return Rfc2898DeriveBytes.Pbkdf2(password, b, 1, HashAlgorithmName.SHA256, length);
        }
        finally
        {
            Array.Clear(b);
        }
    }

    /// <summary>BlockMix with Salsa20/8 on the 2r blocks of 16 words in b; y is scratch space.</summary>
    private static void BlockMix(uint[] b, uint[] y, int r)
    {
        Span<uint> t = stackalloc uint[16];
        b.AsSpan((2 * r - 1) * 16, 16).CopyTo(t);
        for (int i = 0; i < 2 * r; i++)
        {
            for (int k = 0; k < 16; k++)
            {
                t[k] ^= b[(i * 16) + k];
            }
            Salsa208(t);
            // Even blocks to the first half, odd ones to the second.
            t.CopyTo(y.AsSpan(((i / 2) + (i % 2 * r)) * 16, 16));
        }
        Array.Copy(y, b, 32 * r);
    }

    private static void Salsa208(Span<uint> b)
    {
        Span<uint> x = stackalloc uint[16];
        b.CopyTo(x);
        for (int i = 0; i < 8; i += 2)
        {
            x[4] ^= BitOperations.RotateLeft(x[0] + x[12], 7);
            x[8] ^= BitOperations.RotateLeft(x[4] + x[0], 9);
            x[12] ^= BitOperations.RotateLeft(x[8] + x[4], 13);
            x[0] ^= BitOperations.RotateLeft(x[12] + x[8], 18);
            x[9] ^= BitOperations.RotateLeft(x[5] + x[1], 7);
            x[13] ^= BitOperations.RotateLeft(x[9] + x[5], 9);
            x[1] ^= BitOperations.RotateLeft(x[13] + x[9], 13);
            x[5] ^= BitOperations.RotateLeft(x[1] + x[13], 18);
            x[14] ^= BitOperations.RotateLeft(x[10] + x[6], 7);
            x[2] ^= BitOperations.RotateLeft(x[14] + x[10], 9);
            x[6] ^= BitOperations.RotateLeft(x[2] + x[14], 13);
            x[10] ^= BitOperations.RotateLeft(x[6] + x[2], 18);
            x[3] ^= BitOperations.RotateLeft(x[15] + x[11], 7);
            x[7] ^= BitOperations.RotateLeft(x[3] + x[15], 9);
            x[11] ^= BitOperations.RotateLeft(x[7] + x[3], 13);
            x[15] ^= BitOperations.RotateLeft(x[11] + x[7], 18);
            x[1] ^= BitOperations.RotateLeft(x[0] + x[3], 7);
            x[2] ^= BitOperations.RotateLeft(x[1] + x[0], 9);
            x[3] ^= BitOperations.RotateLeft(x[2] + x[1], 13);
            x[0] ^= BitOperations.RotateLeft(x[3] + x[2], 18);
            x[6] ^= BitOperations.RotateLeft(x[5] + x[4], 7);
            x[7] ^= BitOperations.RotateLeft(x[6] + x[5], 9);
            x[4] ^= BitOperations.RotateLeft(x[7] + x[6], 13);
            x[5] ^= BitOperations.RotateLeft(x[4] + x[7], 18);
            x[11] ^= BitOperations.RotateLeft(x[10] + x[9], 7);
            x[8] ^= BitOperations.RotateLeft(x[11] + x[10], 9);
            x[9] ^= BitOperations.RotateLeft(x[8] + x[11], 13);
            x[10] ^= BitOperations.RotateLeft(x[9] + x[8], 18);
            x[12] ^= BitOperations.RotateLeft(x[15] + x[14], 7);
            x[13] ^= BitOperations.RotateLeft(x[12] + x[15], 9);
            x[14] ^= BitOperations.RotateLeft(x[13] + x[12], 13);
            x[15] ^= BitOperations.RotateLeft(x[14] + x[13], 18);
        }
        for (int i = 0; i < 16; i++)
        {
            b[i] += x[i];
        }
    }
}
