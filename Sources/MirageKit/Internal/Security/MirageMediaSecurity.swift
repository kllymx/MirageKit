//
//  MirageMediaSecurity.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Media session key derivation, registration authentication, and packet AEAD helpers.
//

import CryptoKit
import Foundation

package enum MirageMediaDirection: UInt8, Sendable {
    case hostToClient = 1
    case clientToHost = 2
}

package struct MirageMediaSecurityContext: Sendable {
    package let sessionKey: Data
    package let udpRegistrationToken: Data
}

package enum MirageMediaSecurityError: Error {
    case invalidRegistrationTokenLength
    case invalidEncryptedPayloadLength
    case invalidNonce
    case decryptFailed
}

package enum MirageMediaSecurity {
    package static let sessionKeyLength = 32
    package static let registrationTokenLength = 32
    package static let authTagLength = mirageMediaAuthTagSize

    package static func makeRegistrationToken() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    @MainActor
    package static func deriveContext(
        identityManager: MirageIdentityManager,
        peerPublicKey: Data,
        hostID: UUID,
        clientID: UUID,
        hostKeyID: String,
        clientKeyID: String,
        hostNonce: String,
        clientNonce: String,
        udpRegistrationToken: Data
    ) throws -> MirageMediaSecurityContext {
        guard udpRegistrationToken.count == registrationTokenLength else {
            throw MirageMediaSecurityError.invalidRegistrationTokenLength
        }
        let salt = derivationSalt(
            hostID: hostID,
            clientID: clientID,
            hostKeyID: hostKeyID,
            clientKeyID: clientKeyID,
            hostNonce: hostNonce,
            clientNonce: clientNonce
        )
        let key = try identityManager.deriveSharedKey(
            with: peerPublicKey,
            salt: salt,
            sharedInfo: Data("mirage-media-session-v1".utf8),
            outputByteCount: sessionKeyLength
        )
        return MirageMediaSecurityContext(
            sessionKey: key,
            udpRegistrationToken: udpRegistrationToken
        )
    }

    package static func encryptVideoPayload(
        _ plaintext: Data,
        header: FrameHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        try seal(
            plaintext,
            keyData: context.sessionKey,
            nonce: videoNonce(for: header, direction: direction)
        )
    }

    package static func decryptVideoPayload(
        _ wirePayload: Data,
        header: FrameHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        try open(
            wirePayload,
            keyData: context.sessionKey,
            nonce: videoNonce(for: header, direction: direction)
        )
    }

    package static func encryptAudioPayload(
        _ plaintext: Data,
        header: AudioPacketHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        try seal(
            plaintext,
            keyData: context.sessionKey,
            nonce: audioNonce(for: header, direction: direction)
        )
    }

    package static func decryptAudioPayload(
        _ wirePayload: Data,
        header: AudioPacketHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        try open(
            wirePayload,
            keyData: context.sessionKey,
            nonce: audioNonce(for: header, direction: direction)
        )
    }

    package static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let maxLength = max(lhs.count, rhs.count)
        var diff = lhs.count ^ rhs.count
        for index in 0 ..< maxLength {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            diff |= Int(left ^ right)
        }
        return diff == 0
    }

    private static func seal(_ plaintext: Data, keyData: Data, nonce: ChaChaPoly.Nonce) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        var payload = Data()
        payload.reserveCapacity(sealed.ciphertext.count + sealed.tag.count)
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)
        return payload
    }

    private static func open(_ wirePayload: Data, keyData: Data, nonce: ChaChaPoly.Nonce) throws -> Data {
        guard wirePayload.count >= authTagLength else {
            throw MirageMediaSecurityError.invalidEncryptedPayloadLength
        }
        let ciphertextCount = wirePayload.count - authTagLength
        let ciphertext = wirePayload.prefix(ciphertextCount)
        let tag = wirePayload.suffix(authTagLength)
        let key = SymmetricKey(data: keyData)
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        do {
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw MirageMediaSecurityError.decryptFailed
        }
    }

    private static func videoNonce(
        for header: FrameHeader,
        direction: MirageMediaDirection
    ) throws -> ChaChaPoly.Nonce {
        var nonce = Data(count: 12)
        nonce[0] = 1
        nonce[1] = direction.rawValue
        nonce[2] = 1
        nonce[3] = UInt8(truncatingIfNeeded: header.epoch)
        withUnsafeBytes(of: header.streamID.littleEndian) {
            nonce.replaceSubrange(4 ..< 6, with: $0)
        }
        withUnsafeBytes(of: header.sequenceNumber.littleEndian) {
            nonce.replaceSubrange(6 ..< 10, with: $0)
        }
        withUnsafeBytes(of: header.fragmentIndex.littleEndian) {
            nonce.replaceSubrange(10 ..< 12, with: $0)
        }
        return try nonceFromData(nonce)
    }

    private static func audioNonce(
        for header: AudioPacketHeader,
        direction: MirageMediaDirection
    ) throws -> ChaChaPoly.Nonce {
        var nonce = Data(count: 12)
        nonce[0] = 1
        nonce[1] = direction.rawValue
        nonce[2] = 2
        nonce[3] = 0
        withUnsafeBytes(of: header.streamID.littleEndian) {
            nonce.replaceSubrange(4 ..< 6, with: $0)
        }
        withUnsafeBytes(of: header.sequenceNumber.littleEndian) {
            nonce.replaceSubrange(6 ..< 10, with: $0)
        }
        withUnsafeBytes(of: header.fragmentIndex.littleEndian) {
            nonce.replaceSubrange(10 ..< 12, with: $0)
        }
        return try nonceFromData(nonce)
    }

    private static func nonceFromData(_ data: Data) throws -> ChaChaPoly.Nonce {
        do {
            return try ChaChaPoly.Nonce(data: data)
        } catch {
            throw MirageMediaSecurityError.invalidNonce
        }
    }

    private static func derivationSalt(
        hostID: UUID,
        clientID: UUID,
        hostKeyID: String,
        clientKeyID: String,
        hostNonce: String,
        clientNonce: String
    ) -> Data {
        let canonical = [
            ("clientID", clientID.uuidString.lowercased()),
            ("clientKeyID", clientKeyID),
            ("clientNonce", clientNonce),
            ("hostID", hostID.uuidString.lowercased()),
            ("hostKeyID", hostKeyID),
            ("hostNonce", hostNonce),
            ("type", "media-key-derivation-v1"),
        ]
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\n")
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }
}
