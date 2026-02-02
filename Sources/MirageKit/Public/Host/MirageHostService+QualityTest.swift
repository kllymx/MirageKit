//
//  MirageHostService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Host-side quality test handling.
//

import Foundation
import Network

#if os(macOS)
@MainActor
extension MirageHostService {
    func handleQualityTestRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        guard let request = try? message.decode(QualityTestRequestMessage.self) else {
            MirageLogger.host("Failed to decode quality test request")
            return
        }

        if request.includeCodecBenchmark {
            await sendCodecBenchmarkResult(testID: request.testID, to: connection)
        }

        guard let udpConnection = qualityTestConnectionsByClientID[client.id] else {
            MirageLogger.host("Quality test skipped - no UDP registration for client \(client.name)")
            return
        }

        if let task = qualityTestTasksByClientID[client.id] {
            task.cancel()
        }

        let task = Task.detached(priority: .userInitiated) { [request, udpConnection] in
            await Self.sendQualityTestPackets(
                to: udpConnection,
                testID: request.testID,
                plan: request.plan,
                payloadBytes: request.payloadBytes
            )
        }
        qualityTestTasksByClientID[client.id] = task
    }

    private func sendCodecBenchmarkResult(testID: UUID, to connection: NWConnection) async {
        let store = MirageCodecBenchmarkStore()
        var record = store.load()
        if record?.version != MirageCodecBenchmarkStore.currentVersion || record?.hostEncodeMs == nil {
            let encodeMs = try? await MirageCodecBenchmark.runEncodeBenchmark()
            record = MirageCodecBenchmarkStore.Record(
                version: MirageCodecBenchmarkStore.currentVersion,
                benchmarkWidth: MirageCodecBenchmark.benchmarkWidth,
                benchmarkHeight: MirageCodecBenchmark.benchmarkHeight,
                benchmarkFrameRate: MirageCodecBenchmark.benchmarkFrameRate,
                hostEncodeMs: encodeMs,
                clientDecodeMs: nil,
                measuredAt: Date()
            )
            if let record {
                store.save(record)
            }
        }

        let result = QualityTestResultMessage(
            testID: testID,
            benchmarkWidth: record?.benchmarkWidth ?? MirageCodecBenchmark.benchmarkWidth,
            benchmarkHeight: record?.benchmarkHeight ?? MirageCodecBenchmark.benchmarkHeight,
            benchmarkFrameRate: record?.benchmarkFrameRate ?? MirageCodecBenchmark.benchmarkFrameRate,
            encodeMs: record?.hostEncodeMs,
            benchmarkVersion: record?.version ?? MirageCodecBenchmarkStore.currentVersion
        )

        if let message = try? ControlMessage(type: .qualityTestResult, content: result) {
            connection.send(content: message.serialize(), completion: .idempotent)
        }
    }

    private static func sendQualityTestPackets(
        to connection: NWConnection,
        testID: UUID,
        plan: MirageQualityTestPlan,
        payloadBytes: Int
    ) async {
        let payloadLength = UInt16(clamping: payloadBytes)
        let payload = Data(repeating: 0, count: payloadBytes)
        var sequence: UInt32 = 0

        for stage in plan.stages {
            let durationSeconds = Double(stage.durationMs) / 1000.0
            let packetSize = Double(payloadBytes + mirageQualityTestHeaderSize)
            let packetsPerSecond = packetSize > 0
                ? (Double(stage.targetBitrateBps) / 8.0) / packetSize
                : 0
            let interval = packetsPerSecond > 0 ? 1.0 / packetsPerSecond : 0
            let stageStart = CFAbsoluteTimeGetCurrent()

            while CFAbsoluteTimeGetCurrent() - stageStart < durationSeconds {
                if Task.isCancelled { return }
                let timestampNs = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000_000)
                let header = QualityTestPacketHeader(
                    testID: testID,
                    stageID: UInt16(stage.id),
                    sequenceNumber: sequence,
                    timestampNs: timestampNs,
                    payloadLength: payloadLength
                )
                var packet = header.serialize()
                packet.append(payload)
                connection.send(content: packet, completion: .idempotent)
                sequence &+= 1

                if interval > 0 {
                    try? await Task.sleep(for: .seconds(interval))
                } else {
                    await Task.yield()
                }
            }
        }
    }
}
#endif
