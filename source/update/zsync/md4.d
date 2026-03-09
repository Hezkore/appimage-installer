// MD4 (RFC 1320) implementation used for strong per-block checksum verification
module update.zsync.md4;

private uint rotateLeft(uint value, int bitCount) {
    return (value << bitCount) | (value >>> (32 - bitCount));
}

// Returns the 16-byte MD4 digest of data
package ubyte[16] computeMd4(const(ubyte)[] input) {
    uint[4] digestState = [
        0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u
    ];
    ulong bitLen = cast(ulong)(input.length) * 8;
    size_t padEnd = ((input.length + 8) / 64 + 1) * 64;
    ubyte[] msg;
    msg.length = padEnd;
    msg[0 .. input.length] = input[];
    msg[input.length] = 0x80;
    foreach (byteOffset; 0 .. 8)
        msg[padEnd - 8 + byteOffset] = cast(ubyte)(bitLen >> (byteOffset * 8));

    for (size_t blockStart = 0; blockStart < msg.length; blockStart += 64) {
        uint[16] blockWords;
        foreach (wordIndex; 0 .. 16) {
            size_t wordByteOffset = blockStart + wordIndex * 4;
            blockWords[wordIndex] = msg[wordByteOffset]
                | (cast(
                        uint) msg[wordByteOffset + 1] << 8)
                | (cast(uint) msg[wordByteOffset + 2] << 16)
                | (
                    cast(uint) msg[wordByteOffset + 3] << 24);
        }
        uint stateA = digestState[0];
        uint stateB = digestState[1];
        uint stateC = digestState[2];
        uint stateD = digestState[3];
        uint roundFilter(uint b, uint c, uint d) {
            return (b & c) | (~b & d);
        }

        uint roundMajority(uint b, uint c, uint d) {
            return (b & c) | (b & d) | (c & d);
        }

        uint roundParity(uint b, uint c, uint d) {
            return b ^ c ^ d;
        }

        // Round 1
        stateA = rotateLeft(
            stateA + roundFilter(stateB, stateC, stateD) + blockWords[0], 3);
        stateD = rotateLeft(
            stateD + roundFilter(stateA, stateB, stateC) + blockWords[1], 7);
        stateC = rotateLeft(
            stateC + roundFilter(stateD, stateA, stateB) + blockWords[2], 11);
        stateB = rotateLeft(
            stateB + roundFilter(stateC, stateD, stateA) + blockWords[3], 19);
        stateA = rotateLeft(
            stateA + roundFilter(stateB, stateC, stateD) + blockWords[4], 3);
        stateD = rotateLeft(
            stateD + roundFilter(stateA, stateB, stateC) + blockWords[5], 7);
        stateC = rotateLeft(
            stateC + roundFilter(stateD, stateA, stateB) + blockWords[6], 11);
        stateB = rotateLeft(
            stateB + roundFilter(stateC, stateD, stateA) + blockWords[7], 19);
        stateA = rotateLeft(
            stateA + roundFilter(stateB, stateC, stateD) + blockWords[8], 3);
        stateD = rotateLeft(
            stateD + roundFilter(stateA, stateB, stateC) + blockWords[9], 7);
        stateC = rotateLeft(
            stateC + roundFilter(stateD, stateA, stateB) + blockWords[10], 11);
        stateB = rotateLeft(
            stateB + roundFilter(stateC, stateD, stateA) + blockWords[11], 19);
        stateA = rotateLeft(
            stateA + roundFilter(stateB, stateC, stateD) + blockWords[12], 3);
        stateD = rotateLeft(
            stateD + roundFilter(stateA, stateB, stateC) + blockWords[13], 7);
        stateC = rotateLeft(
            stateC + roundFilter(stateD, stateA, stateB) + blockWords[14], 11);
        stateB = rotateLeft(
            stateB + roundFilter(stateC, stateD, stateA) + blockWords[15], 19);

        // Round 2
        enum uint k2 = 0x5A827999u;
        stateA = rotateLeft(
            stateA + roundMajority(stateB, stateC, stateD) + blockWords[0] + k2, 3);
        stateD = rotateLeft(
            stateD + roundMajority(stateA, stateB, stateC) + blockWords[4] + k2, 5);
        stateC = rotateLeft(
            stateC + roundMajority(stateD, stateA, stateB) + blockWords[8] + k2, 9);
        stateB = rotateLeft(
            stateB + roundMajority(stateC, stateD, stateA) + blockWords[12] + k2, 13);
        stateA = rotateLeft(
            stateA + roundMajority(stateB, stateC, stateD) + blockWords[1] + k2, 3);
        stateD = rotateLeft(
            stateD + roundMajority(stateA, stateB, stateC) + blockWords[5] + k2, 5);
        stateC = rotateLeft(
            stateC + roundMajority(stateD, stateA, stateB) + blockWords[9] + k2, 9);
        stateB = rotateLeft(
            stateB + roundMajority(stateC, stateD, stateA) + blockWords[13] + k2, 13);
        stateA = rotateLeft(
            stateA + roundMajority(stateB, stateC, stateD) + blockWords[2] + k2, 3);
        stateD = rotateLeft(
            stateD + roundMajority(stateA, stateB, stateC) + blockWords[6] + k2, 5);
        stateC = rotateLeft(
            stateC + roundMajority(stateD, stateA, stateB) + blockWords[10] + k2, 9);
        stateB = rotateLeft(
            stateB + roundMajority(stateC, stateD, stateA) + blockWords[14] + k2, 13);
        stateA = rotateLeft(
            stateA + roundMajority(stateB, stateC, stateD) + blockWords[3] + k2, 3);
        stateD = rotateLeft(
            stateD + roundMajority(stateA, stateB, stateC) + blockWords[7] + k2, 5);
        stateC = rotateLeft(
            stateC + roundMajority(stateD, stateA, stateB) + blockWords[11] + k2, 9);
        stateB = rotateLeft(
            stateB + roundMajority(stateC, stateD, stateA) + blockWords[15] + k2, 13);

        // Round 3
        enum uint k3 = 0x6ED9EBA1u;
        stateA = rotateLeft(
            stateA + roundParity(stateB, stateC, stateD) + blockWords[0] + k3, 3);
        stateD = rotateLeft(
            stateD + roundParity(stateA, stateB, stateC) + blockWords[8] + k3, 9);
        stateC = rotateLeft(
            stateC + roundParity(stateD, stateA, stateB) + blockWords[4] + k3, 11);
        stateB = rotateLeft(
            stateB + roundParity(stateC, stateD, stateA) + blockWords[12] + k3, 15);
        stateA = rotateLeft(
            stateA + roundParity(stateB, stateC, stateD) + blockWords[2] + k3, 3);
        stateD = rotateLeft(
            stateD + roundParity(stateA, stateB, stateC) + blockWords[10] + k3, 9);
        stateC = rotateLeft(
            stateC + roundParity(stateD, stateA, stateB) + blockWords[6] + k3, 11);
        stateB = rotateLeft(
            stateB + roundParity(stateC, stateD, stateA) + blockWords[14] + k3, 15);
        stateA = rotateLeft(
            stateA + roundParity(stateB, stateC, stateD) + blockWords[1] + k3, 3);
        stateD = rotateLeft(
            stateD + roundParity(stateA, stateB, stateC) + blockWords[9] + k3, 9);
        stateC = rotateLeft(
            stateC + roundParity(stateD, stateA, stateB) + blockWords[5] + k3, 11);
        stateB = rotateLeft(
            stateB + roundParity(stateC, stateD, stateA) + blockWords[13] + k3, 15);
        stateA = rotateLeft(
            stateA + roundParity(stateB, stateC, stateD) + blockWords[3] + k3, 3);
        stateD = rotateLeft(
            stateD + roundParity(stateA, stateB, stateC) + blockWords[11] + k3, 9);
        stateC = rotateLeft(
            stateC + roundParity(stateD, stateA, stateB) + blockWords[7] + k3, 11);
        stateB = rotateLeft(
            stateB + roundParity(stateC, stateD, stateA) + blockWords[15] + k3, 15);

        digestState[0] += stateA;
        digestState[1] += stateB;
        digestState[2] += stateC;
        digestState[3] += stateD;
    }
    ubyte[16] out_;
    foreach (stateIndex; 0 .. 4)
        foreach (outputByte; 0 .. 4)
            out_[stateIndex * 4 + outputByte] =
                cast(ubyte)(digestState[stateIndex] >> (outputByte * 8));
    return out_;
}

// RFC 1320 test vectors - catches byte-order regressions in the MD4 round constants
unittest {
    assert(computeMd4(cast(const(ubyte)[]) "") ==
            cast(ubyte[16])[
                0x31, 0xd6, 0xcf, 0xe0, 0xd1, 0x6a, 0xe9, 0x31,
                0xb7, 0x3c, 0x59, 0xd7, 0xe0, 0xc0, 0x89, 0xc0
            ]);
    assert(computeMd4(cast(const(ubyte)[]) "a") ==
            cast(ubyte[16])[
                0xbd, 0xe5, 0x2c, 0xb3, 0x1d, 0xe3, 0x3e, 0x46,
                0x24, 0x5e, 0x05, 0xfb, 0xdb, 0xd6, 0xfb, 0x24
            ]);
    assert(computeMd4(cast(const(ubyte)[]) "abc") ==
            cast(ubyte[16])[
                0xa4, 0x48, 0x01, 0x7a, 0xaf, 0x21, 0xd8, 0x52,
                0x5f, 0xc1, 0x0a, 0xe8, 0x7a, 0xa6, 0x72, 0x9d
            ]);
    assert(computeMd4(cast(const(ubyte)[]) "message digest") ==
            cast(ubyte[16])[
                0xd9, 0x13, 0x0a, 0x81, 0x64, 0x54, 0x9f, 0xe8,
                0x18, 0x87, 0x48, 0x06, 0xe1, 0xc7, 0x01, 0x4b
            ]);
    assert(computeMd4(cast(const(ubyte)[]) "abcdefghijklmnopqrstuvwxyz") ==
            cast(
                ubyte[16])[
                0xd7, 0x9e, 0x1c, 0x30, 0x8a, 0xa5, 0xbb, 0xcd,
                0xee, 0xa8, 0xed, 0x63, 0xdf, 0x41, 0x2d, 0xa9
            ]);
}
