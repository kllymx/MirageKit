//
//  MirageClientService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Client-side quality test support.
//

import Foundation
import Network

@MainActor
extension MirageClientService {
    public func runQualityTest(plan: MirageQualityTestPlan) async throws -> MirageQualityTestSummary {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let testID = UUID()
        let payloadBytes = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        let accumulator = QualityTestAccumulator(testID: testID, plan: plan, payloadBytes: payloadBytes)
        setQualityTestAccumulator(accumulator, testID: testID)
        defer { clearQualityTestAccumulator() }

        let rttMs = try await measureRTT()
        let benchmarkRecord = try await ensureDecodeBenchmark()

        if udpConnection == nil {
            try await startVideoConnection()
        }
        try await sendQualityTestRegistration()

        let request = QualityTestRequestMessage(
            testID: testID,
            plan: plan,
            payloadBytes: payloadBytes,
            includeCodecBenchmark: true
        )
        let message = try ControlMessage(type: .qualityTestRequest, content: request)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }

        let hostBenchmark = await awaitQualityTestResult(testID: testID, timeout: .seconds(10))
        let totalDurationMs = plan.totalDurationMs
        try await Task.sleep(for: .milliseconds(totalDurationMs + 500))
        try Task.checkCancellation()

        let stageResults = accumulator.makeStageResults()
        let evaluation = evaluateStageResults(stageResults)

        return MirageQualityTestSummary(
            testID: testID,
            rttMs: rttMs,
            lossPercent: evaluation.lossPercent,
            maxStableBitrateBps: evaluation.maxStableBitrateBps,
            targetFrameRate: getScreenMaxRefreshRate(),
            benchmarkWidth: benchmarkRecord.benchmarkWidth,
            benchmarkHeight: benchmarkRecord.benchmarkHeight,
            hostEncodeMs: hostBenchmark?.encodeMs,
            clientDecodeMs: benchmarkRecord.clientDecodeMs,
            stageResults: stageResults
        )
    }

    func handlePong(_: ControlMessage) {
        pingContinuation?.resume()
        pingContinuation = nil
    }

    func handleQualityTestResult(_ message: ControlMessage) {
        guard let result = try? message.decode(QualityTestResultMessage.self) else { return }
        guard qualityTestPendingTestID == result.testID else { return }
        qualityTestResultContinuation?.resume(returning: result)
        qualityTestResultContinuation = nil
        qualityTestPendingTestID = nil
    }

    nonisolated func handleQualityTestPacket(_ header: QualityTestPacketHeader, data: Data) {
        qualityTestLock.lock()
        let accumulator = qualityTestAccumulatorStorage
        let activeTestID = qualityTestActiveTestIDStorage
        qualityTestLock.unlock()

        guard let accumulator, activeTestID == header.testID else { return }
        let payloadBytes = min(Int(header.payloadLength), max(0, data.count - mirageQualityTestHeaderSize))
        accumulator.record(stageID: Int(header.stageID), payloadBytes: payloadBytes)
    }

    private func measureRTT() async throws -> Double {
        var samples: [Double] = []

        for _ in 0 ..< 3 {
            let start = CFAbsoluteTimeGetCurrent()
            try await sendPingAndAwaitPong()
            let delta = (CFAbsoluteTimeGetCurrent() - start) * 1000
            samples.append(delta)
        }

        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func sendPingAndAwaitPong() async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }
        guard pingContinuation == nil else {
            throw MirageError.protocolError("Ping already in flight")
        }

        let message = ControlMessage(type: .ping)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pingContinuation = continuation
            connection.send(content: message.serialize(), completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    pingContinuation?.resume(throwing: error)
                    pingContinuation = nil
                }
            })

            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1))
                if let pingContinuation = self.pingContinuation {
                    pingContinuation.resume(throwing: MirageError.protocolError("Ping timed out"))
                    self.pingContinuation = nil
                }
            }
        }
    }

    private func awaitQualityTestResult(testID: UUID, timeout: Duration) async -> QualityTestResultMessage? {
        if let pending = qualityTestPendingTestID, pending != testID {
            qualityTestResultContinuation?.resume(returning: nil)
            qualityTestResultContinuation = nil
        }

        qualityTestPendingTestID = testID

        return await withCheckedContinuation { continuation in
            qualityTestResultContinuation = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: timeout)
                guard let continuation = self.qualityTestResultContinuation else { return }
                continuation.resume(returning: nil)
                self.qualityTestResultContinuation = nil
                self.qualityTestPendingTestID = nil
            }
        }
    }

    private func sendQualityTestRegistration() async throws {
        guard let udpConnection else {
            throw MirageError.protocolError("No UDP connection")
        }

        var data = Data()
        withUnsafeBytes(of: mirageQualityTestMagic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            udpConnection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    private func ensureDecodeBenchmark() async throws -> MirageCodecBenchmarkStore.Record {
        let store = MirageCodecBenchmarkStore()
        if let record = store.load(),
           record.version == MirageCodecBenchmarkStore.currentVersion,
           record.clientDecodeMs != nil {
            return record
        }

        let decodeMs = try await MirageCodecBenchmark.runDecodeBenchmark()
        let record = MirageCodecBenchmarkStore.Record(
            version: MirageCodecBenchmarkStore.currentVersion,
            benchmarkWidth: MirageCodecBenchmark.benchmarkWidth,
            benchmarkHeight: MirageCodecBenchmark.benchmarkHeight,
            benchmarkFrameRate: MirageCodecBenchmark.benchmarkFrameRate,
            hostEncodeMs: nil,
            clientDecodeMs: decodeMs,
            measuredAt: Date()
        )
        store.save(record)
        return record
    }

    private func evaluateStageResults(
        _ stageResults: [MirageQualityTestSummary.StageResult]
    ) -> (maxStableBitrateBps: Int, lossPercent: Double) {
        var maxStable = 0
        var lossPercent = 0.0

        for stage in stageResults {
            let throughputOk = Double(stage.throughputBps) >= Double(stage.targetBitrateBps) * 0.9
            let lossOk = stage.lossPercent <= 1
            if throughputOk && lossOk {
                maxStable = stage.targetBitrateBps
                lossPercent = stage.lossPercent
            }
        }

        if maxStable == 0, let first = stageResults.first {
            maxStable = first.throughputBps
            lossPercent = first.lossPercent
        }

        return (maxStable, lossPercent)
    }

    nonisolated private func setQualityTestAccumulator(_ accumulator: QualityTestAccumulator, testID: UUID) {
        qualityTestLock.lock()
        qualityTestAccumulatorStorage = accumulator
        qualityTestActiveTestIDStorage = testID
        qualityTestLock.unlock()
    }

    private func clearQualityTestAccumulator() {
        qualityTestLock.lock()
        qualityTestAccumulatorStorage = nil
        qualityTestActiveTestIDStorage = nil
        qualityTestLock.unlock()
    }
}
