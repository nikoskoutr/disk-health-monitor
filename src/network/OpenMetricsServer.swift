// ============================================================================
// File: OpenMetricsServer.swift
// Module: Layer 3 (Telemetry & Networking)
// Purpose: Built-in loopback OpenMetrics / Prometheus HTTP exporter (METRICS-01).
//          Exposes scrapeable hardware health metrics on 127.0.0.1:<port>/metrics
//          and JSON snapshots on /status.json without third-party web servers.
// Concurrency: Thread-safe; reads snapshot under leaf snapshotLock (< 50µs hold time).
// ============================================================================

import Foundation
import Network

public final class OpenMetricsServer {
    public static let shared = OpenMetricsServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var currentPort: Int = 9108
    private var isRunning: Bool = false

    public var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentPort
    }

    private init() {}

    /// Starts the loopback HTTP server on the specified port.
    public func start(port: Int = 9108) {
        lock.lock()
        defer { lock.unlock() }

        if isRunning && currentPort == port {
            return
        }

        stopLocked()

        let clampedPort = UInt16(min(max(1024, port), 65535))
        self.currentPort = Int(clampedPort)

        do {
            let tcpOptions = NWProtocolTCP.Options()
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: clampedPort)!
            )

            let newListener = try NWListener(using: params)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    ConfigManager.shared.log("OpenMetrics server listening on http://127.0.0.1:\(clampedPort)/metrics")
                case .failed(let err):
                    ConfigManager.shared.log("OpenMetrics server failed on port \(clampedPort): \(err.localizedDescription)")
                    self.stop()
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            newListener.start(queue: DispatchQueue(label: "io.github.disk-health.metrics.server", qos: .utility))
            self.listener = newListener
            self.isRunning = true
        } catch {
            ConfigManager.shared.log("Failed to start OpenMetrics server on port \(clampedPort): \(error.localizedDescription)")
            self.isRunning = false
        }
    }

    /// Stops the loopback HTTP server.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        if let l = listener {
            l.cancel()
            listener = nil
            isRunning = false
            ConfigManager.shared.log("OpenMetrics server stopped")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue.global(qos: .utility))
        receiveRequest(connection: connection)
    }

    private func receiveRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self else {
                connection.cancel()
                return
            }
            if let data = data, !data.isEmpty, let req = String(data: data, encoding: .utf8) {
                let fullResponse = self.routeRequest(req)
                if let outData = fullResponse.data(using: .utf8) {
                    connection.send(content: outData, completion: .contentProcessed({ _ in
                        connection.cancel()
                    }))
                    return
                }
            }
            connection.cancel()
        }
    }

    func routeRequest(_ req: String) -> String {
        let firstLine = req.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return makeResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "Bad Request\n")
        }

        let method = parts[0]
        guard method == "GET" || method == "HEAD" else {
            return makeResponse(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: "Method Not Allowed\n")
        }

        let rawTarget = parts[1]
        let path = String(rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")

        switch path {
        case "/metrics":
            let body = method == "HEAD" ? "" : generatePrometheusMetrics()
            return makeResponse(status: "200 OK", contentType: "text/plain; version=0.0.4; charset=utf-8", body: body)

        case "/status.json":
            let snap = DiskHealthMonitor.shared.currentMultiSnapshot
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snap), let jsonStr = String(data: data, encoding: .utf8) {
                return makeResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: method == "HEAD" ? "" : jsonStr)
            }
            return makeResponse(status: "500 Internal Server Error", contentType: "application/json; charset=utf-8", body: "{\"error\":\"encode_failed\"}\n")

        case "/healthz":
            let json = "{\"status\":\"ok\",\"version\":\"\(kAppVersion)\",\"build\":\"\(kAppBuildNumber)\"}\n"
            return makeResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: method == "HEAD" ? "" : json)

        case "/", "/index.html":
            let body = """
            <!DOCTYPE html>
            <html>
            <head><title>Disk Health Monitor</title></head>
            <body style="font-family:sans-serif;padding:2rem;">
            <h2>Universal Disk Health Monitor v\(kAppVersion)</h2>
            <p>Available endpoints:</p>
            <ul>
              <li><a href="/metrics">/metrics</a> (Prometheus / OpenMetrics exposition)</li>
              <li><a href="/status.json">/status.json</a> (Live multi-disk JSON telemetry)</li>
              <li><a href="/healthz">/healthz</a> (Health check)</li>
            </ul>
            </body>
            </html>\n
            """
            return makeResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: method == "HEAD" ? "" : body)

        default:
            return makeResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "Not Found\n")
        }
    }

    private func makeResponse(status: String, contentType: String, body: String) -> String {
        let length = body.utf8.count
        return "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n\(body)"
    }

    /// Formats live snapshots as standard OpenMetrics / Prometheus gauge and counter exposition.
    public func generatePrometheusMetrics() -> String {
        let multi = DiskHealthMonitor.shared.currentMultiSnapshot
        let drives = multi?.disks ?? []
        var lines: [String] = []

        lines.append("# HELP disk_health_score Overall disk health composite score (0-100)")
        lines.append("# TYPE disk_health_score gauge")
        for drive in drives {
            lines.append("disk_health_score{\(labels(for: drive))} \(drive.healthScore)")
        }

        lines.append("# HELP disk_temperature_celsius Drive composite controller temperature in Celsius")
        lines.append("# TYPE disk_temperature_celsius gauge")
        for drive in drives {
            lines.append("disk_temperature_celsius{\(labels(for: drive))} \(drive.temperatureCelsius)")
        }

        lines.append("# HELP disk_percentage_used Drive wear percentage (0% = new, >= 100% = warranty exceeded)")
        lines.append("# TYPE disk_percentage_used gauge")
        for drive in drives {
            lines.append("disk_percentage_used{\(labels(for: drive))} \(drive.percentageUsed)")
        }

        lines.append("# HELP disk_available_spare_percent Remaining available spare percentage (0-100)")
        lines.append("# TYPE disk_available_spare_percent gauge")
        for drive in drives {
            lines.append("disk_available_spare_percent{\(labels(for: drive))} \(drive.availableSpare)")
        }

        lines.append("# HELP disk_free_bytes Filesystem available free capacity in bytes")
        lines.append("# TYPE disk_free_bytes gauge")
        for drive in drives {
            lines.append("disk_free_bytes{\(labels(for: drive))} \(drive.freeBytes)")
        }

        lines.append("# HELP disk_used_percent Volume capacity utilization percentage")
        lines.append("# TYPE disk_used_percent gauge")
        for drive in drives {
            lines.append("disk_used_percent{\(labels(for: drive))} \(String(format: "%.2f", drive.usedPercent))")
        }

        lines.append("# HELP disk_io_latency_ms Recent read/write I/O latency in milliseconds")
        lines.append("# TYPE disk_io_latency_ms gauge")
        for drive in drives {
            lines.append("disk_io_latency_ms{\(labels(for: drive))} \(String(format: "%.3f", max(drive.avgReadLatencyMs, drive.avgWriteLatencyMs)))")
        }

        lines.append("# HELP disk_critical_warning_bitmask NVMe S.M.A.R.T. critical warning bitmask")
        lines.append("# TYPE disk_critical_warning_bitmask gauge")
        for drive in drives {
            lines.append("disk_critical_warning_bitmask{\(labels(for: drive))} \(drive.criticalWarning)")
        }

        lines.append("# HELP disk_media_errors Cumulative unrecoverable media data integrity errors")
        lines.append("# TYPE disk_media_errors counter")
        for drive in drives {
            lines.append("disk_media_errors{\(labels(for: drive))} \(drive.mediaErrors)")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func labels(for drive: DiskHealthSnapshot) -> String {
        let bsd = sanitize(drive.bsdName)
        let model = sanitize(drive.productName)
        let mount = sanitize(drive.mountPoint)
        let bus = sanitize(drive.interconnectType)
        let isInt = drive.isInternal ? "1" : "0"
        return "bsd_name=\"\(bsd)\",model=\"\(model)\",mount=\"\(mount)\",interconnect=\"\(bus)\",is_internal=\"\(isInt)\""
    }

    private func sanitize(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
