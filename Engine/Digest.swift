import Foundation

enum Digest {
    static func sha256(_ data: Data) -> [UInt8] {
        sha256Bytes([UInt8](data))
    }

    static func sha256Hex(_ text: String) -> String {
        hex(sha256Bytes([UInt8](text.utf8)))
    }

    static func md5Hex(_ text: String) -> String {
        hex(md5Bytes([UInt8](text.utf8)))
    }

    static func hmacSHA256(_ message: Data, key: [UInt8]) -> [UInt8] {
        let block = 64
        var k = key
        if k.count > block { k = sha256Bytes(k) }
        if k.count < block { k.append(contentsOf: repeatElement(0, count: block - k.count)) }
        var ipad = [UInt8](repeating: 0x36, count: block)
        var opad = [UInt8](repeating: 0x5c, count: block)
        for i in 0..<block {
            ipad[i] ^= k[i]
            opad[i] ^= k[i]
        }
        return sha256Bytes(opad + sha256Bytes(ipad + [UInt8](message)))
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes
    }

    private static let shaK: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private static func sha256Bytes(_ message: [UInt8]) -> [UInt8] {
        var msg = message
        let bitCount = UInt64(msg.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19
        var offset = 0
        while offset < msg.count {
            var w = [UInt32](repeating: 0, count: 64)
            for t in 0..<16 {
                let o = offset + t * 4
                w[t] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16) | (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ ch &+ shaK[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                h = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
            offset += 64
        }
        var out: [UInt8] = []
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static let md5S: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let md5K: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    private static func md5Bytes(_ message: [UInt8]) -> [UInt8] {
        var msg = message
        let bitCount = UInt64(msg.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        var length = bitCount
        for _ in 0..<8 {
            msg.append(UInt8(length & 0xff))
            length >>= 8
        }
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476
        var offset = 0
        while offset < msg.count {
            var m = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let o = offset + j * 4
                m[j] = UInt32(msg[o]) | (UInt32(msg[o + 1]) << 8) | (UInt32(msg[o + 2]) << 16) | (UInt32(msg[o + 3]) << 24)
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                let f: UInt32
                let g: Int
                if i < 16 {
                    f = (b & c) | (~b & d)
                    g = i
                } else if i < 32 {
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                } else if i < 48 {
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                } else {
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                let next = a &+ f &+ md5K[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotl(next, md5S[i])
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
            offset += 64
        }
        var out: [UInt8] = []
        for word in [a0, b0, c0, d0] {
            out.append(UInt8(word & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 24) & 0xff))
        }
        return out
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
