// PDF passwords (export-pdf.adoc, "Interactive" and "Client"; IO-027): the standard security
// handler with AES, never RC4 for content.  PDF 2.0 files use revision 6 (AES-256, `/V 5`,
// `/CFM /AESV3`: SHA-2 password hashing, `/UE` and `/OE` wrapping one random file key, `/Perms`);
// PDF 1.4 to 1.7 files use revision 4 (AES-128, `/V 4`, `/CFM /AESV2`: MD5 key derivation, the
// RC4 steps of algorithms 3 and 5 only computing `/O` and `/U`, a key per object).  Every string
// and stream is encrypted except the encryption dictionary itself; each gets a random 16-byte IV
// in front of its PKCS#7-padded AES-CBC ciphertext.  The *Open password* is the user password;
// the *Permissions password* is the owner password (the open password when none is given), and
// `/P` carries what anyone without it may do.  Accessibility extraction is always allowed.

import CommonCrypto
import CryptoKit
import Foundation

final class PDFEncryption {
    enum Revision {
        /// AES-128, PDF 1.6 and later (written for 1.4 to 1.7, raising the header to 1.6).
        case r4
        /// AES-256, PDF 2.0.
        case r6
    }

    let revision: Revision
    /// The file identifier: fixed before any object is encrypted, since revision 4 keys use it.
    let fileID: Data
    /// `/P`.
    let permissions: Int32
    /// The file key (16 bytes for revision 4, 32 for revision 6).
    let key: Data
    /// The encryption dictionary.
    let dictionary: PDFValue
    /// The object number of the encryption dictionary, which is not encrypted.
    var exempt: Int?
    /// Random bytes (IVs, salts, keys); tests may make them deterministic.
    let random: (Int) -> Data

    static let padding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]

    /// `/P` for the three permissions: the reserved bits set, printing (bits 3 and 12), copying
    /// (bit 5; bit 10, accessibility, always) and editing (bits 4, 6, 9 and 11).
    static func permissions(printing: Bool, copying: Bool, editing: Bool) -> Int32 {
        var bits: UInt32 = 0xFFFF_F0C0 | 0x200
        if printing { bits |= 0x4 | 0x800 }
        if copying { bits |= 0x10 }
        if editing { bits |= 0x8 | 0x20 | 0x100 | 0x400 }
        return Int32(bitPattern: bits)
    }

    static func secureRandom(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    init(revision: Revision, userPassword: String, ownerPassword: String, permissions: Int32, random: @escaping (Int) -> Data = PDFEncryption.secureRandom) {
        self.revision = revision
        self.permissions = permissions
        self.random = random
        fileID = random(16)
        let owner = ownerPassword.isEmpty ? userPassword : ownerPassword
        switch revision {
        case .r4:
            let user = PDFEncryption.padded(userPassword)
            let o = PDFEncryption.ownerEntry(owner: PDFEncryption.padded(owner), user: user)
            let key = PDFEncryption.r4Key(user: user, owner: o, permissions: permissions, id: fileID)
            self.key = key
            dictionary = .dictionary([
                ("Filter", .name("Standard")), ("V", .int(4)), ("R", .int(4)), ("Length", .int(128)),
                ("CF", .dictionary([("StdCF", .dictionary([("AuthEvent", .name("DocOpen")), ("CFM", .name("AESV2")), ("Length", .int(16))]))])),
                ("StmF", .name("StdCF")), ("StrF", .name("StdCF")),
                ("O", .bytes(o)), ("U", .bytes(PDFEncryption.userEntry(key: key, id: fileID))), ("P", .int(Int(permissions))),
            ])
        case .r6:
            let key = random(32)
            self.key = key
            let user = PDFEncryption.saslPassword(userPassword)
            let ownerBytes = PDFEncryption.saslPassword(owner)
            let (userValidation, userKeySalt) = (random(8), random(8))
            let u = PDFEncryption.hash(user, salt: userValidation, extra: Data()) + userValidation + userKeySalt
            let ue = PDFEncryption.aes(key, key: PDFEncryption.hash(user, salt: userKeySalt, extra: Data()), iv: Data(count: 16), padding: false)
            let (ownerValidation, ownerKeySalt) = (random(8), random(8))
            let o = PDFEncryption.hash(ownerBytes, salt: ownerValidation, extra: u) + ownerValidation + ownerKeySalt
            let oe = PDFEncryption.aes(key, key: PDFEncryption.hash(ownerBytes, salt: ownerKeySalt, extra: u), iv: Data(count: 16), padding: false)
            var perms = Data()
            let p = UInt32(bitPattern: permissions)
            perms.append(contentsOf: [UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24)])
            perms.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
            perms.append(Data("Tadb".utf8))
            perms.append(random(4))
            dictionary = .dictionary([
                ("Filter", .name("Standard")), ("V", .int(5)), ("R", .int(6)), ("Length", .int(256)),
                ("CF", .dictionary([("StdCF", .dictionary([("AuthEvent", .name("DocOpen")), ("CFM", .name("AESV3")), ("Length", .int(32))]))])),
                ("StmF", .name("StdCF")), ("StrF", .name("StdCF")),
                ("O", .bytes(o)), ("U", .bytes(u)), ("OE", .bytes(oe)), ("UE", .bytes(ue)),
                ("P", .int(Int(permissions))), ("Perms", .bytes(PDFEncryption.aesECB(perms, key: key))),
            ])
        }
    }

    /// `data` of object `number` encrypted: IV then AES-CBC ciphertext.
    func encrypt(_ data: Data, object number: Int) -> Data {
        let iv = random(16)
        switch revision {
        case .r6:
            return iv + PDFEncryption.aes(data, key: key, iv: iv, padding: true)
        case .r4:
            var material = key
            material.append(contentsOf: [UInt8(number & 0xFF), UInt8((number >> 8) & 0xFF), UInt8((number >> 16) & 0xFF), 0, 0])
            material.append(Data("sAlT".utf8))
            let objectKey = Data(Insecure.MD5.hash(data: material))
            return iv + PDFEncryption.aes(data, key: objectKey, iv: iv, padding: true)
        }
    }

    // MARK: Revision 4

    /// A password as Latin-1 bytes (characters outside it dropped), padded to 32 bytes.
    static func padded(_ password: String) -> Data {
        let bytes = password.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : nil }.prefix(32)
        return Data(bytes + padding.prefix(32 - bytes.count))
    }

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    /// Algorithm 3: `/O` from the padded owner and user passwords.
    static func ownerEntry(owner: Data, user: Data) -> Data {
        var hash = md5(owner)
        for _ in 0..<50 {
            hash = md5(hash)
        }
        var result = rc4(user, key: hash)
        for round in 1...19 {
            result = rc4(result, key: Data(hash.map { $0 ^ UInt8(round) }))
        }
        return result
    }

    /// Algorithm 2: the file key.
    static func r4Key(user: Data, owner: Data, permissions: Int32, id: Data) -> Data {
        let p = UInt32(bitPattern: permissions)
        var hash = md5(user + owner + Data([UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24)]) + id)
        for _ in 0..<50 {
            hash = md5(hash)
        }
        return hash
    }

    /// Algorithm 5: `/U`.
    static func userEntry(key: Data, id: Data) -> Data {
        var result = rc4(md5(Data(padding) + id), key: key)
        for round in 1...19 {
            result = rc4(result, key: Data(key.map { $0 ^ UInt8(round) }))
        }
        return result + Data(count: 16)
    }

    // MARK: Revision 6

    /// A password as UTF-8 (the SASLprep profile's output for the passwords the sheet takes),
    /// at most 127 bytes.
    static func saslPassword(_ password: String) -> Data {
        Data(password.precomposedStringWithCompatibilityMapping.utf8.prefix(127))
    }

    /// Algorithm 2.B: the revision 6 hash of `password` with an 8-byte `salt` and, for the owner
    /// entries, the 48-byte `/U` as `extra`.
    static func hash(_ password: Data, salt: Data, extra: Data) -> Data {
        var k = Data(SHA256.hash(data: password + salt + extra))
        var round = 0
        var last: UInt8 = 0
        while round < 64 || Int(last) > round - 32 {
            var block = Data()
            let unit = password + k + extra
            for _ in 0..<64 {
                block.append(unit)
            }
            let e = aes(block, key: k.prefix(16), iv: k.subdata(in: (k.startIndex + 16)..<(k.startIndex + 32)), padding: false)
            let remainder = e.prefix(16).reduce(0) { $0 + Int($1) } % 3
            switch remainder {
            case 0: k = Data(SHA256.hash(data: e))
            case 1: k = Data(SHA384.hash(data: e))
            default: k = Data(SHA512.hash(data: e))
            }
            last = e[e.endIndex - 1]
            round += 1
        }
        return k.prefix(32)
    }

    // MARK: Ciphers

    static func crypt(_ data: Data, key: Data, iv: Data?, algorithm: CCAlgorithm, options: CCOptions) -> Data {
        var output = Data(count: data.count + 32)
        var moved = 0
        let outputCount = output.count
        _ = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    if let iv {
                        return iv.withUnsafeBytes { ivBytes in
                            CCCrypt(CCOperation(kCCEncrypt), algorithm, options, keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count, out.baseAddress, outputCount, &moved)
                        }
                    }
                    return CCCrypt(CCOperation(kCCEncrypt), algorithm, options, keyBytes.baseAddress, key.count, nil, input.baseAddress, data.count, out.baseAddress, outputCount, &moved)
                }
            }
        }
        return output.prefix(moved)
    }

    /// AES-CBC (key 16 or 32 bytes); without padding `data` must be whole blocks.
    static func aes(_ data: Data, key: Data, iv: Data, padding: Bool) -> Data {
        crypt(data, key: key, iv: iv, algorithm: CCAlgorithm(kCCAlgorithmAES), options: CCOptions(padding ? kCCOptionPKCS7Padding : 0))
    }

    /// AES-256-ECB of one block (`/Perms`).
    static func aesECB(_ data: Data, key: Data) -> Data {
        crypt(data, key: key, iv: nil, algorithm: CCAlgorithm(kCCAlgorithmAES), options: CCOptions(kCCOptionECBMode))
    }

    /// RC4, for the `/O` and `/U` steps of revision 4 only.
    static func rc4(_ data: Data, key: Data) -> Data {
        crypt(data, key: key, iv: nil, algorithm: CCAlgorithm(kCCAlgorithmRC4), options: 0)
    }
}
