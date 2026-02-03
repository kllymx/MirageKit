//
//  MessageTypes+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Control messages for quality testing.
//

import Foundation

struct QualityTestRequestMessage: Codable {
    let testID: UUID
    let plan: MirageQualityTestPlan
    let payloadBytes: Int
}

struct QualityTestResultMessage: Codable {
    let testID: UUID
    let benchmarkWidth: Int
    let benchmarkHeight: Int
    let benchmarkFrameRate: Int
    let encodeMs: Double?
    let benchmarkVersion: Int
}
