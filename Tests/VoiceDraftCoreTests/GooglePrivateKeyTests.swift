import Foundation
import Security
import XCTest
@testable import VoiceDraftCore

final class GooglePrivateKeyTests: XCTestCase {
    private func derLength(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    private func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + derLength(body.count) + body }
    private func pkcs8(wrapping pkcs1: Data) -> Data {
        let rsaAlgorithm = tlv(0x30, [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        return Data(tlv(0x30, tlv(0x02, [0x00]) + rsaAlgorithm + tlv(0x04, [UInt8](pkcs1))))
    }
    private func pem(_ der: Data, label: String) -> String {
        "-----BEGIN \(label)-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END \(label)-----\n"
    }
    private func makeKey() throws -> (SecKey, Data) {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let exported = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return (key, exported)
    }

    func testPKCS8PEMUnwrapsToPKCS1AndSigns() throws {
        let (original, pkcs1) = try makeKey()
        let text = pem(pkcs8(wrapping: pkcs1), label: "PRIVATE KEY")
        XCTAssertEqual(try GooglePrivateKey.pkcs1DER(fromPEM: text), pkcs1)
        XCTAssertEqual(try GooglePrivateKey.modulusBits(pkcs1: pkcs1), 2048)

        let key = try GooglePrivateKey.secKey(fromPEM: text)
        let message = Data("header.claims".utf8) as CFData
        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(original))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message, signature, &error))
    }

    func testPKCS1PEMPassesThroughUnchanged() throws {
        let (_, pkcs1) = try makeKey()
        let text = pem(pkcs1, label: "RSA PRIVATE KEY")
        XCTAssertEqual(try GooglePrivateKey.pkcs1DER(fromPEM: text), pkcs1)
        XCTAssertNoThrow(try GooglePrivateKey.secKey(fromPEM: text))
    }

    func testGarbageInputThrows() {
        XCTAssertThrowsError(try GooglePrivateKey.pkcs1DER(fromPEM: "not a key"))
        XCTAssertThrowsError(try GooglePrivateKey.pkcs1DER(fromPEM: ""))
        XCTAssertThrowsError(try GooglePrivateKey.pkcs1DER(fromPEM: pem(Data([0x31, 0x03, 0x02, 0x01, 0x00]), label: "PRIVATE KEY")))
        // Truncated multi-byte length.
        XCTAssertThrowsError(try GooglePrivateKey.pkcs1DER(fromPEM: pem(Data([0x30, 0x82, 0x01]), label: "PRIVATE KEY")))
        XCTAssertThrowsError(try GooglePrivateKey.secKey(fromPEM: pem(Data(repeating: 0x41, count: 64), label: "RSA PRIVATE KEY")))
    }
}
