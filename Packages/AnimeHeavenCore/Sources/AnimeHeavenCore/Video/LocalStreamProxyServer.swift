import Foundation
import Network

/// Lightweight loopback HTTP/1.1 Range (`206 Partial Content`) proxy bound strictly to `127.0.0.1`.
/// Feeds `AVPlayer` standard MP4 HTTP ranges backed by `DiskChunkCache` + `StreamingChunkBooster`,
/// providing 0 ms cached range hits, parallel multi-mirror fetching, custom `Referer` headers,
/// seamless mid-stream failover, and full compatibility with `AVPictureInPictureController`.
public actor LocalStreamProxyServer {
    private let booster: StreamingChunkBooster
    private let authToken: String
    private let queue = DispatchQueue(label: "me.animeheaven.ios.streamproxy", qos: .userInitiated)
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var sessions: [String: StreamSessionDescriptor] = [:]

    public init(booster: StreamingChunkBooster) {
        self.booster = booster
        self.authToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func ensureStarted() async throws -> UInt16 {
        if let listener, boundPort > 0, listener.state == .ready {
            return boundPort
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host.ipv4(.loopback),
            port: .any
        )

        let newListener = try NWListener(using: params)
        self.listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            Task.detached(priority: .userInitiated) {
                await self?.handleConnection(connection)
            }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBool()
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.trySetTrue() {
                        let actualPort = newListener.port?.rawValue ?? 0
                        continuation.resume(returning: actualPort)
                    }
                case .failed(let error):
                    if resumed.trySetTrue() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if resumed.trySetTrue() {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            newListener.start(queue: queue)
        }

        self.boundPort = port
        return port
    }

    public func registerSession(_ session: StreamSessionDescriptor) async throws -> URL {
        let port = try await ensureStarted()
        sessions[session.sessionId] = session
        guard let url = URL(string: "http://127.0.0.1:\(port)/stream/\(authToken)/\(session.sessionId).mp4") else {
            throw AnimeHeavenClientError.invalidURL("localhost proxy URL")
        }
        return url
    }

    public func unregisterSession(sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        boundPort = 0
        sessions.removeAll()
    }

    private func lookupSession(_ id: String) -> StreamSessionDescriptor? {
        sessions[id]
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: queue)
        defer { connection.cancel() }

        guard let requestData = await receiveHeaderBlock(from: connection),
              let parsed = Self.parseHttpRequest(requestData) else {
            await sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }

        let expectedPrefix = "/stream/\(authToken)/"
        guard parsed.path.hasPrefix(expectedPrefix), parsed.path.hasSuffix(".mp4") else {
            await sendRaw("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }

        let startDrop = parsed.path.dropFirst(expectedPrefix.count)
        let sessionId = String(startDrop.dropLast(4))
        guard let session = lookupSession(sessionId), session.totalLength > 0 else {
            await sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }

        let total = session.totalLength
        let rangeResult = Self.resolveByteRange(rangeHeader: parsed.rangeHeader, totalLength: total)
        guard let (rangeStart, rangeEnd, isPartial) = rangeResult else {
            await sendRaw(
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                on: connection
            )
            return
        }

        let contentLength = rangeEnd - rangeStart + 1
        let statusLine = isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
        var header = "\(statusLine)\r\n"
        header += "Content-Type: video/mp4\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Content-Length: \(contentLength)\r\n"
        if isPartial {
            header += "Content-Range: bytes \(rangeStart)-\(rangeEnd)/\(total)\r\n"
        }
        header += "Connection: close\r\n\r\n"

        guard await sendData(Data(header.utf8), on: connection) else { return }
        if parsed.method == "HEAD" { return }

        var cursor = rangeStart
        while cursor <= rangeEnd {
            if Task.isCancelled { return }
            let chunkStart = DiskChunkCache.alignChunkStart(cursor)
            guard let chunkData = await booster.getOrFetchChunk(session: session, chunkOffset: chunkStart) else {
                return
            }
            let sliceStart = Int(cursor - chunkStart)
            guard sliceStart < chunkData.count else { return }
            let remainingInRequest = Int(rangeEnd - cursor + 1)
            let availableInChunk = chunkData.count - sliceStart
            let bytesToSend = min(remainingInRequest, availableInChunk)
            let slice = chunkData.subdata(in: sliceStart..<(sliceStart + bytesToSend))
            guard await sendData(slice, on: connection) else { return }
            cursor += Int64(bytesToSend)
        }
    }

    private func receiveHeaderBlock(from connection: NWConnection) async -> Data? {
        var buffer = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while buffer.count < 16 * 1024 {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete || error != nil {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            guard let chunk else { break }
            buffer.append(chunk)
            if buffer.range(of: delimiter) != nil {
                return buffer
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func sendRaw(_ text: String, on connection: NWConnection) async {
        _ = await sendData(Data(text.utf8), on: connection)
    }

    private func sendData(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    internal struct ParsedHttpRequest: Sendable {
        let method: String
        let path: String
        let rangeHeader: String?
    }

    internal static func parseHttpRequest(_ data: Data) -> ParsedHttpRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?").first.map(String.init) ?? rawTarget

        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "range" {
                    rangeHeader = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return ParsedHttpRequest(method: method, path: path, rangeHeader: rangeHeader)
    }

    internal static func resolveByteRange(
        rangeHeader: String?,
        totalLength: Int64
    ) -> (start: Int64, end: Int64, isPartial: Bool)? {
        guard totalLength > 0 else { return nil }
        guard let rangeHeader, rangeHeader.lowercased().hasPrefix("bytes=") else {
            return (0, totalLength - 1, false)
        }
        let spec = String(rangeHeader.dropFirst(6)).split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let startStr = bounds[0].trimmingCharacters(in: .whitespaces)
        let endStr = bounds[1].trimmingCharacters(in: .whitespaces)

        if startStr.isEmpty {
            // Suffix range: bytes=-N
            guard let suffix = Int64(endStr), suffix > 0 else { return nil }
            let start = max(0, totalLength - suffix)
            return (start, totalLength - 1, true)
        }

        guard let start = Int64(startStr), start >= 0, start < totalLength else { return nil }
        let end: Int64
        if endStr.isEmpty {
            end = totalLength - 1
        } else if let parsedEnd = Int64(endStr) {
            end = min(totalLength - 1, parsedEnd)
        } else {
            return nil
        }
        guard start <= end else { return nil }
        return (start, end, true)
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func trySetTrue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
