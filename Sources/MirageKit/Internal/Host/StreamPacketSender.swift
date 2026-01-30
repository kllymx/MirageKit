//
//  StreamPacketSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
//

import Foundation
import CoreMedia
import CoreGraphics

#if os(macOS)

actor StreamPacketSender {
    struct WorkItem: Sendable {
        let encodedData: Data
        let frameByteCount: Int
        let isKeyframe: Bool
        let presentationTime: CMTime
        let contentRect: CGRect
        let streamID: StreamID
        let frameNumber: UInt32
        let sequenceNumberStart: UInt32
        let additionalFlags: FrameFlags
        let dimensionToken: UInt16
        let epoch: UInt16
        let fecBlockSize: Int
        let lossMode: Bool
        let wireBytes: Int
        let logPrefix: String
        let generation: UInt32
        let onSendStart: (@Sendable () -> Void)?
        let onSendComplete: (@Sendable () -> Void)?
    }

    private let maxPayloadSize: Int
    private let onEncodedFrame: @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    private let packetBufferPool: PacketBufferPool
    private var sendTask: Task<Void, Never>?
    // Accessed from encoder callbacks; lifecycle is managed by start/stop.
    nonisolated(unsafe) private var sendContinuation: AsyncStream<WorkItem>.Continuation?
    // Snapshot read from encoder callbacks to tag enqueued frames.
    nonisolated(unsafe) private var generation: UInt32 = 0
    nonisolated(unsafe) private var queuedBytes: Int = 0
    nonisolated(unsafe) private var dropNonKeyframesUntilKeyframe: Bool = false
    nonisolated(unsafe) private var latestKeyframeFrameNumber: UInt32 = 0
    private let queueLock = NSLock()
    private let basePacingBurstSize = 16
    private let pacingThresholdBytes = 512 * 1024
    private let basePacingDelay = Duration.milliseconds(1)
    private let largeFrameThresholdBytes = 800 * 1024
    private let hugeFrameThresholdBytes = 1_500 * 1024

    init(maxPayloadSize: Int, onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void) {
        self.maxPayloadSize = maxPayloadSize
        self.onEncodedFrame = onEncodedFrame
        self.packetBufferPool = PacketBufferPool(capacity: MirageHeaderSize + maxPayloadSize)
    }

    func start() {
        guard sendTask == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: WorkItem.self, bufferingPolicy: .unbounded)
        sendContinuation = continuation
        queueLock.withLock {
            queuedBytes = 0
        }
        sendTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for await item in stream {
                await self.handle(item)
            }
        }
    }

    func stop() {
        sendContinuation?.finish()
        sendContinuation = nil
        sendTask?.cancel()
        sendTask = nil
        queueLock.withLock {
            queuedBytes = 0
        }
    }

    func bumpGeneration(reason: String) {
        generation &+= 1
        MirageLogger.stream("Packet send generation bumped to \(generation) (\(reason))")
    }

    func resetQueue(reason: String) {
        generation &+= 1
        queueLock.withLock {
            queuedBytes = 0
        }
        MirageLogger.stream("Packet send queue reset (gen \(generation), \(reason))")
    }

    nonisolated func queuedBytesSnapshot() -> Int {
        queueLock.withLock { queuedBytes }
    }

    nonisolated func currentGenerationSnapshot() -> UInt32 {
        generation
    }

    nonisolated func enqueue(_ item: WorkItem) {
        guard sendContinuation != nil else { return }
        queueLock.withLock {
            queuedBytes += item.wireBytes
            if item.isKeyframe {
                dropNonKeyframesUntilKeyframe = true
                latestKeyframeFrameNumber = item.frameNumber
            }
        }
        sendContinuation?.yield(item)
    }

    private func handle(_ item: WorkItem) async {
        let (shouldDropNonKeyframes, newestKeyframe) = queueLock.withLock {
            (dropNonKeyframesUntilKeyframe, latestKeyframeFrameNumber)
        }
        if shouldDropNonKeyframes && !item.isKeyframe {
            queueLock.withLock {
                queuedBytes = max(0, queuedBytes - item.wireBytes)
            }
            return
        }
        if item.isKeyframe, newestKeyframe > 0, item.frameNumber < newestKeyframe {
            queueLock.withLock {
                queuedBytes = max(0, queuedBytes - item.wireBytes)
            }
            MirageLogger.stream("Dropping stale keyframe \(item.frameNumber) (newest \(newestKeyframe))")
            return
        }
        guard item.generation == generation else {
            if item.isKeyframe {
                MirageLogger.stream("Dropping stale keyframe \(item.frameNumber) (gen \(item.generation) != \(generation))")
                queueLock.withLock {
                    if latestKeyframeFrameNumber == item.frameNumber {
                        dropNonKeyframesUntilKeyframe = false
                    }
                }
            }
            queueLock.withLock {
                queuedBytes = max(0, queuedBytes - item.wireBytes)
            }
            return
        }

        if item.isKeyframe {
            item.onSendStart?()
        }
        await fragmentAndSendPackets(item)
        if item.isKeyframe {
            item.onSendComplete?()
            queueLock.withLock {
                if latestKeyframeFrameNumber == item.frameNumber {
                    dropNonKeyframesUntilKeyframe = false
                }
            }
        }
        queueLock.withLock {
            queuedBytes = max(0, queuedBytes - item.wireBytes)
        }
    }

    private func fragmentAndSendPackets(_ item: WorkItem) async {
        let fragmentStartTime = CFAbsoluteTimeGetCurrent()

        let maxPayload = maxPayloadSize
        let frameByteCount = max(0, item.frameByteCount)
        let dataFragmentCount = dataFragmentCount(for: frameByteCount, maxPayload: maxPayload)
        let fecBlockSize = max(0, item.fecBlockSize)
        let parityFragmentCount = parityFragmentCount(
            dataFragmentCount: dataFragmentCount,
            blockSize: fecBlockSize
        )
        let totalFragments = dataFragmentCount + parityFragmentCount
        let timestamp = UInt64(CMTimeGetSeconds(item.presentationTime) * 1_000_000_000)

        let (burstSize, pacingDelay) = pacingConfig(
            for: item.encodedData.count,
            totalFragments: totalFragments,
            lossMode: item.lossMode
        )
        let burstCount = max(1, (totalFragments + burstSize - 1) / burstSize)
        let shouldPace = item.encodedData.count >= pacingThresholdBytes && burstCount > 1

        var currentSequence = item.sequenceNumberStart

        for burstIndex in 0..<burstCount {
            if item.generation != generation {
                MirageLogger.stream("Aborting send for frame \(item.frameNumber) (gen \(item.generation) != \(generation))")
                if item.isKeyframe {
                    queueLock.withLock {
                        if latestKeyframeFrameNumber == item.frameNumber {
                            dropNonKeyframesUntilKeyframe = false
                        }
                    }
                }
                return
            }

            let burstStart = burstIndex * burstSize
            let burstEnd = min(burstStart + burstSize, totalFragments)

            for fragmentIndex in burstStart..<burstEnd {
                var flags = item.additionalFlags
                if fragmentIndex > 0, flags.contains(.discontinuity) {
                    flags.remove(.discontinuity)
                }
                if item.isKeyframe { flags.insert(.keyframe) }
                if fragmentIndex == totalFragments - 1 { flags.insert(.endOfFrame) }
                if item.isKeyframe && fragmentIndex == 0 { flags.insert(.parameterSet) }

                if fragmentIndex < dataFragmentCount {
                    let start = fragmentIndex * maxPayload
                    let end = min(start + maxPayload, frameByteCount)
                    let fragmentSize = end - start
                    guard fragmentSize > 0 else { continue }

                    item.encodedData.withUnsafeBytes { buffer in
                        guard let baseAddress = buffer.baseAddress else { return }
                        let fragmentPtr = baseAddress.advanced(by: start)
                        let fragmentBuffer = UnsafeRawBufferPointer(start: fragmentPtr, count: fragmentSize)
                        let checksum = CRC32.calculate(fragmentBuffer)

                        let header = FrameHeader(
                            flags: flags,
                            streamID: item.streamID,
                            sequenceNumber: currentSequence,
                            timestamp: timestamp,
                            frameNumber: item.frameNumber,
                            fragmentIndex: UInt16(fragmentIndex),
                            fragmentCount: UInt16(totalFragments),
                            payloadLength: UInt32(fragmentSize),
                            frameByteCount: UInt32(frameByteCount),
                            checksum: checksum,
                            contentRect: item.contentRect,
                            dimensionToken: item.dimensionToken,
                            epoch: item.epoch
                        )

                        let packetBuffer = packetBufferPool.acquire()
                        let packetLength = MirageHeaderSize + fragmentSize
                        packetBuffer.prepare(length: packetLength)

                        packetBuffer.withMutableBytes { packetBytes in
                            guard packetBytes.count >= packetLength, let baseAddress = packetBytes.baseAddress else { return }
                            let headerBuffer = UnsafeMutableRawBufferPointer(start: baseAddress, count: min(packetBytes.count, MirageHeaderSize))
                            header.serialize(into: headerBuffer)
                            baseAddress.advanced(by: MirageHeaderSize).copyMemory(from: fragmentPtr, byteCount: fragmentSize)
                        }

                        let packet = packetBuffer.finalize(length: packetLength)
                        let releasePacket: @Sendable () -> Void = { packetBuffer.release() }
                        onEncodedFrame(packet, header, releasePacket)
                    }
                } else if parityFragmentCount > 0 {
                    let parityIndex = fragmentIndex - dataFragmentCount
                    let blockIndex = parityIndex
                    let blockSize = fecBlockSize
                    guard blockSize > 0 else { continue }
                    let blockStart = blockIndex * blockSize
                    let blockEnd = min(blockStart + blockSize, dataFragmentCount)
                    guard blockStart < blockEnd else { continue }

                    let parityLength = parityPayloadLength(
                        frameByteCount: frameByteCount,
                        blockStart: blockStart,
                        maxPayload: maxPayload
                    )
                    let parityData = computeParity(
                        encodedData: item.encodedData,
                        frameByteCount: frameByteCount,
                        blockStart: blockStart,
                        blockEnd: blockEnd,
                        payloadLength: parityLength,
                        maxPayload: maxPayload
                    )
                    guard !parityData.isEmpty else { continue }

                    var parityFlags = flags
                    parityFlags.insert(.fecParity)

                    parityData.withUnsafeBytes { parityBuffer in
                        guard let parityBase = parityBuffer.baseAddress else { return }
                        let checksum = CRC32.calculate(parityBuffer)
                        let header = FrameHeader(
                            flags: parityFlags,
                            streamID: item.streamID,
                            sequenceNumber: currentSequence,
                            timestamp: timestamp,
                            frameNumber: item.frameNumber,
                            fragmentIndex: UInt16(fragmentIndex),
                            fragmentCount: UInt16(totalFragments),
                            payloadLength: UInt32(parityData.count),
                            frameByteCount: UInt32(frameByteCount),
                            checksum: checksum,
                            contentRect: item.contentRect,
                            dimensionToken: item.dimensionToken,
                            epoch: item.epoch
                        )

                        let packetBuffer = packetBufferPool.acquire()
                        let packetLength = MirageHeaderSize + parityData.count
                        packetBuffer.prepare(length: packetLength)

                        packetBuffer.withMutableBytes { packetBytes in
                            guard packetBytes.count >= packetLength, let baseAddress = packetBytes.baseAddress else { return }
                            let headerBuffer = UnsafeMutableRawBufferPointer(start: baseAddress, count: min(packetBytes.count, MirageHeaderSize))
                            header.serialize(into: headerBuffer)
                            baseAddress.advanced(by: MirageHeaderSize).copyMemory(from: parityBase, byteCount: parityData.count)
                        }

                        let packet = packetBuffer.finalize(length: packetLength)
                        let releasePacket: @Sendable () -> Void = { packetBuffer.release() }
                        onEncodedFrame(packet, header, releasePacket)
                    }
                }
                currentSequence += 1
            }

            if shouldPace && burstIndex < burstCount - 1 {
                try? await Task.sleep(for: pacingDelay)
            }
        }

        if item.isKeyframe {
            let fragmentDurationMs = (CFAbsoluteTimeGetCurrent() - fragmentStartTime) * 1000
            let roundedDuration = (fragmentDurationMs * 100).rounded() / 100
            let bytesKB = Double(item.encodedData.count) / 1024.0
            let roundedBytes = (bytesKB * 10).rounded() / 10
            MirageLogger.timing("\(item.logPrefix) \(item.frameNumber) keyframe: \(roundedDuration)ms, \(totalFragments) packets, \(roundedBytes)KB")
        }
    }

    private func dataFragmentCount(for frameByteCount: Int, maxPayload: Int) -> Int {
        guard frameByteCount > 0, maxPayload > 0 else { return 0 }
        return (frameByteCount + maxPayload - 1) / maxPayload
    }

    private func parityFragmentCount(dataFragmentCount: Int, blockSize: Int) -> Int {
        guard dataFragmentCount > 0, blockSize > 1 else { return 0 }
        return (dataFragmentCount + blockSize - 1) / blockSize
    }

    private func parityPayloadLength(frameByteCount: Int, blockStart: Int, maxPayload: Int) -> Int {
        guard frameByteCount > 0, maxPayload > 0 else { return 0 }
        let start = blockStart * maxPayload
        let remaining = max(0, frameByteCount - start)
        return min(maxPayload, remaining)
    }

    private func computeParity(
        encodedData: Data,
        frameByteCount: Int,
        blockStart: Int,
        blockEnd: Int,
        payloadLength: Int,
        maxPayload: Int
    ) -> Data {
        guard payloadLength > 0 else { return Data() }
        var parity = Data(repeating: 0, count: payloadLength)
        parity.withUnsafeMutableBytes { parityBytes in
            let parityPtr = parityBytes.bindMemory(to: UInt8.self)
            guard let parityBase = parityPtr.baseAddress else { return }
            encodedData.withUnsafeBytes { dataBytes in
                let dataPtr = dataBytes.bindMemory(to: UInt8.self)
                guard let dataBase = dataPtr.baseAddress else { return }
                for fragmentIndex in blockStart..<blockEnd {
                    let start = fragmentIndex * maxPayload
                    let remaining = max(0, frameByteCount - start)
                    let fragmentSize = min(maxPayload, remaining)
                    guard fragmentSize > 0 else { continue }
                    let sourcePtr = dataBase.advanced(by: start)
                    let bytesToXor = min(fragmentSize, payloadLength)
                    let src = sourcePtr
                    for i in 0..<bytesToXor {
                        parityBase[i] ^= src[i]
                    }
                }
            }
        }
        return parity
    }

    private func pacingConfig(for encodedBytes: Int, totalFragments: Int, lossMode: Bool) -> (burstSize: Int, pacingDelay: Duration) {
        if encodedBytes >= hugeFrameThresholdBytes {
            if lossMode {
                return (burstSize: min(16, totalFragments), pacingDelay: .microseconds(750))
            }
            return (burstSize: min(32, totalFragments), pacingDelay: .microseconds(250))
        }
        if encodedBytes >= largeFrameThresholdBytes {
            if lossMode {
                return (burstSize: min(12, totalFragments), pacingDelay: .milliseconds(1))
            }
            return (burstSize: min(24, totalFragments), pacingDelay: .microseconds(500))
        }
        if lossMode {
            return (burstSize: min(8, totalFragments), pacingDelay: .microseconds(750))
        }
        return (burstSize: min(basePacingBurstSize, totalFragments), pacingDelay: basePacingDelay)
    }
}

#endif
