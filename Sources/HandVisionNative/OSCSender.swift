import Foundation
import HandVisionCore
import Network

final class OSCSender {
    private let queue = DispatchQueue(label: "site.posedtx.hand-vision-native.osc")
    private var connection: NWConnection?
    private var reconnectWorkItem: DispatchWorkItem?
    private var endpoint = ""
    private var sendWindow = OSCSendWindow(maximumInFlight: 16)
    private var pendingBatches = OSCBatchBuffer(capacity: 16)

    var onError: ((String) -> Void)?

    func configure(host: String, port: Int) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPort = min(65_535, max(1, port))
        let nextEndpoint = "\(cleanHost):\(cleanPort)"

        queue.async { [weak self] in
            guard let self else { return }
            if self.endpoint == nextEndpoint { return }
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.connection?.cancel()
            self.sendWindow.resetForNewConnection()
            self.pendingBatches.removeAll(keepingCapacity: true)
            self.endpoint = nextEndpoint
            self.connect(host: cleanHost, port: UInt16(cleanPort), endpoint: nextEndpoint)
        }
    }

    func send(address: String, arguments: [OSCArgument]) {
        sendBatch([(address: address, arguments: arguments)], coalescingKey: address)
    }

    func sendBatch(
        _ messages: [(address: String, arguments: [OSCArgument])],
        coalescingKey: String
    ) {
        var payloads: [Data] = []
        payloads.reserveCapacity(messages.count)
        do {
            for message in messages {
                payloads.append(try OSCEncoder.encodeMessage(
                    address: message.address,
                    arguments: message.arguments
                ))
            }
        } catch {
            report("OSC batch encode failed: \(error)")
            return
        }
        guard !payloads.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.endpoint.isEmpty else { return }
            self.enqueueOrSend(key: coalescingKey, payloads: payloads)
        }
    }

    @discardableResult
    func sendAndWait(
        address: String,
        arguments: [OSCArgument],
        timeout: TimeInterval = 0.5
    ) -> Bool {
        let payload: Data
        do {
            payload = try OSCEncoder.encodeMessage(address: address, arguments: arguments)
        } catch {
            report("OSC encode failed for \(address): \(error)")
            return false
        }

        let completed = DispatchSemaphore(value: 0)
        var delivered = false
        queue.async { [weak self] in
            guard let connection = self?.connection else {
                completed.signal()
                return
            }
            connection.send(content: payload, completion: .contentProcessed { error in
                delivered = error == nil
                completed.signal()
            })
        }
        return completed.wait(timeout: .now() + timeout) == .success && delivered
    }

    func shutdown() {
        queue.sync {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connection?.cancel()
            connection = nil
            sendWindow.resetForNewConnection()
            pendingBatches.removeAll()
            endpoint = ""
        }
    }

    private func connect(host: String, port: UInt16, endpoint expectedEndpoint: String) {
        guard endpoint == expectedEndpoint,
              let portValue = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: portValue,
            using: .udp
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection,
                  self.connection === connection,
                  self.endpoint == expectedEndpoint else { return }
            switch state {
            case .ready:
                self.sendWindow.setReady(true)
                self.report("")
                self.flushPendingBatches()
            case .failed(let error):
                self.sendWindow.setReady(false)
                if self.isMissingUDPListener(error) {
                    self.report("")
                } else {
                    self.report("OSC connection failed: \(error.localizedDescription); retrying.")
                }
                self.retry(
                    failedConnection: connection,
                    host: host,
                    port: port,
                    endpoint: expectedEndpoint
                )
            case .waiting(let error):
                self.sendWindow.setReady(false)
                // Network.framework keeps a waiting connection alive and
                // automatically retries when the route becomes available.
                if self.isMissingUDPListener(error) {
                    self.report("")
                } else {
                    self.report("OSC waiting: \(error.localizedDescription)")
                }
            default:
                if case .cancelled = state {
                    self.sendWindow.setReady(false)
                }
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func retry(
        failedConnection: NWConnection,
        host: String,
        port: UInt16,
        endpoint expectedEndpoint: String
    ) {
        guard connection === failedConnection, endpoint == expectedEndpoint else { return }
        failedConnection.cancel()
        connection = nil
        sendWindow.resetForNewConnection()
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.endpoint == expectedEndpoint, self.connection == nil else { return }
            self.reconnectWorkItem = nil
            self.connect(host: host, port: port, endpoint: expectedEndpoint)
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func enqueueOrSend(key: String, payloads: [Data]) {
        guard connection != nil, sendWindow.canSend(batchSize: payloads.count) else {
            pendingBatches.store(key: key, payloads: payloads)
            return
        }
        sendPayloads(payloads)
    }

    private func sendPayloads(_ payloads: [Data]) {
        guard sendWindow.canSend(batchSize: payloads.count), let connection else { return }
        sendWindow.recordSend(batchSize: payloads.count)
        for payload in payloads {
            connection.send(content: payload, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, self.connection === connection else { return }
                self.sendWindow.recordCompletion()
                if let error, !self.isMissingUDPListener(error) {
                    self.report("OSC send failed: \(error.localizedDescription)")
                }
                self.flushPendingBatches()
            })
        }
    }

    private func flushPendingBatches() {
        while let batch = pendingBatches.first,
              connection != nil,
              sendWindow.canSend(batchSize: batch.payloads.count) {
            _ = pendingBatches.removeFirst()
            sendPayloads(batch.payloads)
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private func isMissingUDPListener(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return OSCTransportErrorPolicy.isMissingUDPListener(posixCode: code.rawValue)
    }
}
