//
//  MirageClientService+Video.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  UDP video transport and keyframe recovery.
//

import Foundation
import Network
import MirageKit

@MainActor
extension MirageClientService {
    /// Start UDP connection to host's data port for receiving video.
    func startVideoConnection() async throws {
        guard hostDataPort > 0 else { throw MirageError.protocolError("Host data port not set") }

        guard let connection else { throw MirageError.protocolError("No TCP connection") }

        let host: NWEndpoint.Host
        if case let .hostPort(h, _) = connection.endpoint { host = h } else if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                                                                               case let .hostPort(h, _) = remoteEndpoint {
            host = h
        } else {
            MirageLogger.client("Using Bonjour endpoint for UDP")
            if case .service = connection.endpoint {
                if let connectedHost {
                    let dataEndpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(connectedHost.name),
                        port: NWEndpoint.Port(rawValue: hostDataPort)!
                    )
                    MirageLogger
                        .client("Connecting to host data port via hostname \(connectedHost.name):\(hostDataPort)")
                    let params = NWParameters.udp
                    params.serviceClass = .interactiveVideo
                    params.includePeerToPeer = networkConfig.enablePeerToPeer

                    let udpConn = NWConnection(to: dataEndpoint, using: params)
                    udpConnection = udpConn
                    udpConn.pathUpdateHandler = { path in
                        MirageLogger.client("UDP path updated: \(describeNetworkPath(path))")
                    }

                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let box = ContinuationBox<Void>(continuation)
                        udpConn.stateUpdateHandler = { [box] state in
                            switch state {
                            case .ready:
                                box.resume()
                            case let .failed(error):
                                box.resume(throwing: error)
                            case .cancelled:
                                box.resume(throwing: MirageError.protocolError("UDP connection cancelled"))
                            default:
                                break
                            }
                        }
                        udpConn.start(queue: .global(qos: .userInteractive))
                    }
                    MirageLogger.client("UDP connection established to host data port")
                    if let path = udpConn.currentPath {
                        MirageLogger.client("UDP connection path: \(describeNetworkPath(path))")
                    }
                    startReceivingVideo()
                    return
                }
            }
            throw MirageError.protocolError("Cannot determine host address")
        }

        let dataEndpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(rawValue: hostDataPort)!)
        MirageLogger.client("Connecting to host data port at \(host):\(hostDataPort)")

        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        let udpConn = NWConnection(to: dataEndpoint, using: params)
        udpConnection = udpConn
        udpConn.pathUpdateHandler = { path in
            MirageLogger.client("UDP path updated: \(describeNetworkPath(path))")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox<Void>(continuation)

            udpConn.stateUpdateHandler = { [box] state in
                switch state {
                case .ready:
                    box.resume()
                case let .failed(error):
                    box.resume(throwing: error)
                case .cancelled:
                    box.resume(throwing: MirageError.protocolError("UDP connection cancelled"))
                default:
                    break
                }
            }

            udpConn.start(queue: .global(qos: .userInteractive))
        }

        MirageLogger.client("UDP connection established to host data port")
        if let path = udpConn.currentPath {
            MirageLogger.client("UDP connection path: \(describeNetworkPath(path))")
        }
        startReceivingVideo()
    }

    /// Start receiving video data from UDP connection.
    private func startReceivingVideo() {
        guard let udpConn = udpConnection else { return }
        startUDPReceiveLoop(udpConnection: udpConn, service: self)
    }

    /// Start the UDP receive loop in a nonisolated context.
    private nonisolated func startUDPReceiveLoop(
        udpConnection: NWConnection,
        service: MirageClientService
    ) {
        @Sendable
        func receiveNext() {
            udpConnection
                .receive(minimumIncompleteLength: 4, maximumLength: 65536) { data, _, _, error in
                    if let data {
                        if let testHeader = QualityTestPacketHeader.deserialize(from: data) {
                            service.handleQualityTestPacket(testHeader, data: data)
                            receiveNext()
                            return
                        }

                        if data.count >= mirageHeaderSize, let header = FrameHeader.deserialize(from: data) {
                            let streamID = header.streamID

                            guard service.activeStreamIDsForFiltering.contains(streamID) else {
                                receiveNext()
                                return
                            }

                            if streamID == service.qualityProbeTransportStreamIDForFiltering {
                                let payload = data.dropFirst(mirageHeaderSize)
                                let payloadBytes = min(Int(header.payloadLength), payload.count)
                                service.recordQualityProbeTransportBytes(payloadBytes)
                            }

                            if service.takeStartupPacketPending(streamID) {
                                Task { @MainActor in
                                    service.logStartupFirstPacketIfNeeded(streamID: streamID)
                                    service.cancelStartupRegistrationRetry(streamID: streamID)
                                }
                            }

                            guard let reassembler = service.reassemblerForStream(streamID) else {
                                receiveNext()
                                return
                            }

                            let payload = data.dropFirst(mirageHeaderSize)
                            if payload.count != Int(header.payloadLength) {
                                MirageLogger
                                    .client(
                                        "UDP payload length mismatch for stream \(streamID): header=\(header.payloadLength), actual=\(payload.count)"
                                    )
                                receiveNext()
                                return
                            }
                            reassembler.processPacket(payload, header: header)
                        }
                    }

                    if let error {
                        MirageLogger.error(.client, "UDP receive error: \(error)")
                        return
                    }

                    receiveNext()
                }
        }

        receiveNext()
    }

    /// Send stream registration to host via UDP.
    func sendStreamRegistration(streamID: StreamID) async throws {
        guard let udpConn = udpConnection else { throw MirageError.protocolError("No UDP connection") }

        var data = Data()
        data.append(contentsOf: [0x4D, 0x49, 0x52, 0x47])
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }

        MirageLogger.client("Sending stream registration for stream \(streamID)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            udpConn.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }

        MirageLogger.client("Stream registration sent")
        if let baseTime = streamStartupBaseTimes[streamID],
           !streamStartupFirstRegistrationSent.contains(streamID) {
            streamStartupFirstRegistrationSent.insert(streamID)
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
            MirageLogger.client("Desktop start: stream registration sent for stream \(streamID) (+\(deltaMs)ms)")
        }
        lastKeyframeRequestTime[streamID] = CFAbsoluteTimeGetCurrent()
    }

    func logStartupFirstPacketIfNeeded(streamID: StreamID) {
        guard let baseTime = streamStartupBaseTimes[streamID],
              !streamStartupFirstPacketReceived.contains(streamID) else {
            return
        }
        streamStartupFirstPacketReceived.insert(streamID)
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
        MirageLogger.client("Desktop start: first UDP packet received for stream \(streamID) (+\(deltaMs)ms)")
    }

    /// Stop the video connection.
    func stopVideoConnection() {
        udpConnection?.cancel()
        udpConnection = nil
        hostDataPort = 0
    }

    /// Request a keyframe from the host when decoder encounters errors.
    func sendKeyframeRequest(for streamID: StreamID) {
        guard case .connected = connectionState, let connection else {
            MirageLogger.client("Cannot send keyframe request - not connected")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if let lastTime = lastKeyframeRequestTime[streamID], now - lastTime < keyframeRequestCooldown {
            let remaining = Int(((keyframeRequestCooldown - (now - lastTime)) * 1000).rounded())
            MirageLogger.client("Keyframe request skipped (cooldown \(remaining)ms) for stream \(streamID)")
            return
        }
        lastKeyframeRequestTime[streamID] = now

        let request = KeyframeRequestMessage(streamID: streamID)
        guard let message = try? ControlMessage(type: .keyframeRequest, content: request) else {
            MirageLogger.error(.client, "Failed to create keyframe request message")
            return
        }

        let data = message.serialize()
        connection.send(content: data, completion: .idempotent)
        MirageLogger.client("Sent keyframe request for stream \(streamID)")
    }

    /// Request stream recovery by forcing a keyframe.
    public func requestStreamRecovery(for streamID: StreamID) {
        guard case .connected = connectionState else {
            MirageLogger.client("Stream recovery skipped - not connected")
            return
        }

        MirageLogger.client("Stream recovery requested for stream \(streamID)")

        MirageFrameCache.shared.clear(for: streamID)

        Task { [weak self] in
            guard let self else { return }
            await controllersByStream[streamID]?.requestRecovery()

            do {
                if udpConnection == nil { try await startVideoConnection() }
                try await sendStreamRegistration(streamID: streamID)
            } catch {
                MirageLogger.error(.client, "Stream recovery registration failed: \(error)")
                stopVideoConnection()
            }
        }
    }

    func sendStreamEncoderSettingsChange(
        streamID: StreamID,
        pixelFormat: MiragePixelFormat? = nil,
        colorSpace: MirageColorSpace? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }
        guard pixelFormat != nil || colorSpace != nil || bitrate != nil || streamScale != nil else { return }

        let clampedScale = streamScale.map(clampStreamScale)
        let request = StreamEncoderSettingsChangeMessage(
            streamID: streamID,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            bitrate: bitrate,
            streamScale: clampedScale
        )
        let message = try ControlMessage(type: .streamEncoderSettingsChange, content: request)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    func handleAdaptiveFallbackTrigger(for streamID: StreamID) {
        guard adaptiveFallbackEnabled else {
            MirageLogger.client("Adaptive fallback skipped (disabled) for stream \(streamID)")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let lastApplied = adaptiveFallbackLastAppliedTime[streamID] ?? 0
        if lastApplied > 0, now - lastApplied < adaptiveFallbackCooldown {
            let remainingMs = Int(((adaptiveFallbackCooldown - (now - lastApplied)) * 1000).rounded())
            MirageLogger.client("Adaptive fallback cooldown \(remainingMs)ms for stream \(streamID)")
            return
        }

        guard let currentBitrate = adaptiveFallbackBitrateByStream[streamID], currentBitrate > 0 else {
            MirageLogger.client("Adaptive fallback skipped (missing baseline bitrate) for stream \(streamID)")
            return
        }
        guard let nextBitrate = Self.nextAdaptiveFallbackBitrate(
            currentBitrate: currentBitrate,
            step: adaptiveFallbackBitrateStep,
            floor: adaptiveFallbackBitrateFloorBps
        ) else {
            let floorText = Double(adaptiveFallbackBitrateFloorBps / 1_000_000)
                .formatted(.number.precision(.fractionLength(1)))
            MirageLogger.client("Adaptive fallback floor reached (\(floorText) Mbps) for stream \(streamID)")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await sendStreamEncoderSettingsChange(streamID: streamID, bitrate: nextBitrate)
                adaptiveFallbackBitrateByStream[streamID] = nextBitrate
                adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                let fromMbps = (Double(currentBitrate) / 1_000_000.0)
                    .formatted(.number.precision(.fractionLength(1)))
                let toMbps = (Double(nextBitrate) / 1_000_000.0)
                    .formatted(.number.precision(.fractionLength(1)))
                MirageLogger.client("Adaptive fallback bitrate step \(fromMbps) → \(toMbps) Mbps for stream \(streamID)")
            } catch {
                MirageLogger.error(.client, "Failed to apply adaptive fallback for stream \(streamID): \(error)")
            }
        }
    }

    nonisolated static func nextAdaptiveFallbackBitrate(
        currentBitrate: Int,
        step: Double,
        floor: Int
    )
    -> Int? {
        guard currentBitrate > 0 else { return nil }
        let clampedStep = max(0.0, min(step, 1.0))
        let clampedFloor = max(1, floor)
        let steppedBitrate = Int((Double(currentBitrate) * clampedStep).rounded(.down))
        let nextBitrate = max(clampedFloor, steppedBitrate)
        return nextBitrate < currentBitrate ? nextBitrate : nil
    }

    func handleVideoPacket(_ data: Data, header: FrameHeader) async {
        delegate?.clientService(self, didReceiveVideoPacket: data, forStream: header.streamID)
    }
}

private func describeNetworkPath(_ path: NWPath) -> String {
    var interfaces: [String] = []
    if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
    if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
    if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
    if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
    if path.usesInterfaceType(.other) { interfaces.append("other") }
    let interfaceText = interfaces.isEmpty ? "unknown" : interfaces.joined(separator: ",")
    let available = path.availableInterfaces
        .map { "\($0.name)(\(String(describing: $0.type)))" }
        .joined(separator: ",")
    let availableText = available.isEmpty ? "none" : available
    return "status=\(path.status), interfaces=\(interfaceText), available=\(availableText), expensive=\(path.isExpensive), constrained=\(path.isConstrained), ipv4=\(path.supportsIPv4), ipv6=\(path.supportsIPv6)"
}
