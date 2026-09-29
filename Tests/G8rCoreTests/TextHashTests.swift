import XCTest
@testable import G8rCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class TextHashTests: XCTestCase {
    /// The examples in FIPS 180-4's SHA-256 test data.
    private let known = [
        "": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "abc": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq":
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    ]

    func testKnownDigests() {
        for (text, digest) in known {
            XCTAssertEqual(TextHash.sha256(text), digest, text)
        }
        XCTAssertEqual(TextHash.sha256("naïve — 計画"), TextHash.hex(TextHash.portableSHA256(Array("naïve — 計画".utf8))),
                       "the bytes hashed are the text's UTF-8")
    }

    /// The digest used where there is no CryptoKit has to give the same
    /// file names, or a cache wouldn't survive a move between machines.
    func testThePortableDigestIsTheSameDigest() {
        for (text, digest) in known {
            XCTAssertEqual(TextHash.hex(TextHash.portableSHA256(Array(text.utf8))), digest, text)
        }
        XCTAssertEqual(TextHash.hex(TextHash.portableSHA256([UInt8](repeating: 0x61, count: 1_000_000))),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    #if canImport(CryptoKit)
    func testThePortableDigestAgreesWithCryptoKitAroundTheBlockSize() {
        for length in [1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 121, 128, 1000] {
            let message = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            XCTAssertEqual(TextHash.portableSHA256(message), Array(SHA256.hash(data: Data(message))),
                           "\(length) bytes")
        }
    }
    #endif
}
