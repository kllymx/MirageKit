//
//  QualityTestAccumulator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Thread-safe accumulation for quality test UDP packets.
//

import Foundation

final class QualityTestAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesByStage: [Int: Int] = [:]
    private var packetsByStage: [Int: Int] = [:]

    let testID: UUID
    let plan: MirageQualityTestPlan
    let payloadBytes: Int

    init(testID: UUID, plan: MirageQualityTestPlan, payloadBytes: Int) {
        self.testID = testID
        self.plan = plan
        self.payloadBytes = payloadBytes
    }

    func record(stageID: Int, payloadBytes: Int) {
        lock.lock()
        bytesByStage[stageID, default: 0] += payloadBytes
        packetsByStage[stageID, default: 0] += 1
        lock.unlock()
    }

    func makeStageResults() -> [MirageQualityTestSummary.StageResult] {
        lock.lock()
        let bytesSnapshot = bytesByStage
        lock.unlock()

        return plan.stages.map { stage in
            let receivedBytes = bytesSnapshot[stage.id, default: 0]
            let expectedBytes = max(0, stage.targetBitrateBps * stage.durationMs / 1000 / 8)
            let throughputBps = stage.durationMs > 0
                ? Int(Double(receivedBytes * 8) / (Double(stage.durationMs) / 1000.0))
                : 0
            let lossPercent = expectedBytes > 0
                ? max(0, (1 - Double(receivedBytes) / Double(expectedBytes)) * 100)
                : 0

            return MirageQualityTestSummary.StageResult(
                stageID: stage.id,
                targetBitrateBps: stage.targetBitrateBps,
                durationMs: stage.durationMs,
                throughputBps: throughputBps,
                lossPercent: lossPercent
            )
        }
    }
}
