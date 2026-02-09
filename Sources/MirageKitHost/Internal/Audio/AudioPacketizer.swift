//
//  AudioPacketizer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Audio packet fragmentation for UDP transport.
//

import Foundation
import MirageKit

#if os(macOS)

actor AudioPacketizer {
    private let maxPayloadSize: Int
    private var frameNumber: UInt32 = 0
    private var sequenceNumber: UInt32 = 0

    init(maxPayloadSize: Int) {
        self.maxPayloadSize = max(1, maxPayloadSize)
    }

    func resetCounters() {
        frameNumber = 0
        sequenceNumber = 0
    }

    func packetize(
        frame: EncodedAudioFrame,
        streamID: StreamID,
        discontinuity: Bool = false
    ) -> [Data] {
        guard !frame.data.isEmpty else { return [] }
        let fragmentCount = max(1, (frame.data.count + maxPayloadSize - 1) / maxPayloadSize)
        let totalFragments = min(fragmentCount, Int(UInt16.max))
        let currentFrameNumber = frameNumber
        frameNumber &+= 1

        var packets: [Data] = []
        packets.reserveCapacity(totalFragments)

        for fragmentIndex in 0 ..< totalFragments {
            let start = fragmentIndex * maxPayloadSize
            let end = min(frame.data.count, start + maxPayloadSize)
            let payloadCount = max(0, end - start)
            guard payloadCount > 0 else { continue }
            let payload = frame.data.subdata(in: start ..< end)
            let checksum = CRC32.calculate(payload)
            var flags: AudioPacketFlags = []
            if discontinuity, fragmentIndex == 0 { flags.insert(.discontinuity) }

            let header = AudioPacketHeader(
                codec: frame.codec,
                flags: flags,
                streamID: streamID,
                sequenceNumber: sequenceNumber,
                timestamp: frame.timestampNs,
                frameNumber: currentFrameNumber,
                fragmentIndex: UInt16(fragmentIndex),
                fragmentCount: UInt16(totalFragments),
                payloadLength: UInt16(payloadCount),
                frameByteCount: UInt32(frame.data.count),
                sampleRate: UInt32(frame.sampleRate),
                channelCount: UInt8(frame.channelCount),
                samplesPerFrame: UInt16(clamping: frame.samplesPerFrame),
                checksum: checksum
            )
            sequenceNumber &+= 1

            var packet = header.serialize()
            packet.append(payload)
            packets.append(packet)
        }

        return packets
    }
}

#endif
