import Foundation
import Network

/// Lightweight loopback HTTP/1.1 Range (`206 Partial Content`) proxy bound strictly to `127.0.0.1`.
/// Feeds `AVPlayer` standard MP4 HTTP ranges backed by `DiskChunkCache` + `StreamingChunkBooster`,
/// providing 0 ms cached range hits, parallel multi-mirror fetching, custom `Referer` headers,
/// seamless mid-stream failover, and full compatibility with `AVPictureInPictureController`.
public actor LocalStreamProxyServer {
    private let booster: StreamingChunkBooster
    private let authToken: String
    private let upstreamSession: URLSession
    private let queue = DispatchQueue(label: "me.animeheaven.ios.streamproxy", qos: .userInitiated)
    private var listener: NWListener?
    private var startTask: Task<UInt16, Error>?
    private var boundPort: UInt16 = 0
    private var sessions: [String: StreamSessionDescriptor] = [:]

    public init(booster: StreamingChunkBooster) {
        self.booster = booster
        self.authToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 600
        config.httpShouldSetCookies = false
        self.upstreamSession = URLSession(configuration: config)
    }

    deinit {
        startTask?.cancel()
        listener?.cancel()
        upstreamSession.invalidateAndCancel()
    }

    public func ensureStarted() async throws -> UInt16 {
        if let listener, boundPort > 0, listener.state == .ready {
            return boundPort
        }
        if let startTask { return try await startTask.value }
        listener?.cancel()
        boundPort = 0

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host.ipv4(.loopback),
            port: .any
        )

        let newListener = try NWListener(using: params)
        self.listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            Task.detached(priority: .userInitiated) {
                if let self { await self.handleConnection(connection) } else { connection.cancel() }
            }
        }

        let queue = self.queue
        let task = Task { try await Self.start(newListener, queue: queue) }
        startTask = task
        do {
            let port = try await task.value
            guard listener === newListener else { throw CancellationError() }
            boundPort = port
            startTask = nil
            return port
        } catch {
            if listener === newListener {
                newListener.cancel()
                listener = nil
                startTask = nil
            }
            throw error
        }
    }

    private static func start(_ newListener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBool()
            newListener.stateUpdateHandler = { [weak newListener] state in
                switch state {
                case .ready:
                    if resumed.trySetTrue() {
                        if let port = newListener?.port?.rawValue, port > 0 {
                            continuation.resume(returning: port)
                        } else {
                            continuation.resume(throwing: URLError(.cannotConnectToHost))
                        }
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
        } onCancel: {
            newListener.cancel()
        }
    }

    public func registerSession(_ session: StreamSessionDescriptor) async throws -> URL {
        let port = try await ensureStarted()
        try Task.checkCancellation()
        guard listener != nil else { throw CancellationError() }
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
        startTask?.cancel()
        startTask = nil
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

        let headerResult = await receiveHeaderBlock(from: connection)
        if case .tooLarge = headerResult {
            await sendRaw("HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        guard case let .complete(requestData) = headerResult, let parsed = Self.parseHttpRequest(requestData) else {
            await sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        guard parsed.method == "GET" || parsed.method == "HEAD" else {
            await sendRaw("HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }

        let expectedPrefix = "/stream/\(authToken)/"
        guard parsed.path.hasPrefix(expectedPrefix), parsed.path.hasSuffix(".mp4") else {
            await sendRaw("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }

        let startDrop = parsed.path.dropFirst(expectedPrefix.count)
        let sessionId = String(startDrop.dropLast(4))
        guard let session = lookupSession(sessionId) else {
            await sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        if session.totalLength <= 0 {
            await forwardToMirror(session: session, request: parsed, on: connection)
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

    /// Mirrors without verified range metadata still need a Referer. Stream them directly,
    /// without writing unverified bytes to the shared episode cache.
    private func forwardToMirror(
        session: StreamSessionDescriptor, request: ParsedHttpRequest, on connection: NWConnection
    ) async {
        if let range = request.rangeHeader, !range.lowercased().hasPrefix("bytes=") || range.contains(",") {
            await sendRaw("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        guard let mirror = session.mirrors.first, let url = URL(string: mirror),
              url.scheme?.lowercased() == "https", url.host != nil else { return }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.setValue(request.rangeHeader, forHTTPHeaderField: "Range")
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        upstream.setValue(AnimeHeavenClient.userAgent, forHTTPHeaderField: "User-Agent")
        upstream.setValue("\(AnimeHeavenClient.baseURL)/", forHTTPHeaderField: "Referer")

        var headersSent = false
        do {
            let (bytes, response) = try await upstreamSession.bytes(for: upstream)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let status: String
            switch http.statusCode {
            case 200: status = "200 OK"
            case 206: status = "206 Partial Content"
            case 416: status = "416 Range Not Satisfiable"
            default: throw URLError(.badServerResponse)
            }
            let type = (http.mimeType ?? "").lowercased()
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity",
                  http.statusCode == 416 || (!type.hasPrefix("text/") && !type.contains("html") && !type.contains("json")) else {
                throw URLError(.badServerResponse)
            }
            var header = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\nConnection: close\r\n"
            for field in ["Content-Length", "Content-Range", "Accept-Ranges"] {
                if let value = http.value(forHTTPHeaderField: field), !value.contains("\r"), !value.contains("\n") {
                    header += "\(field): \(value)\r\n"
                }
            }
            headersSent = true
            guard await sendData(Data((header + "\r\n").utf8), on: connection), request.method != "HEAD" else { return }
            let batchSize = 32 * 1024
            var buffer = Data()
            buffer.reserveCapacity(batchSize)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == batchSize {
                    guard await sendData(buffer, on: connection) else { return }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { _ = await sendData(buffer, on: connection) }
        } catch {
            if !headersSent {
                await sendRaw("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            }
        }
    }

    private static let maxHeaderBytes = 16 * 1024
    private enum HeaderRead { case complete(Data), incomplete, tooLarge }

    private func receiveHeaderBlock(from connection: NWConnection) async -> HeaderRead {
        let timeout = Self.startTimeout(on: connection)
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await readHeader(from: connection)
        } onCancel: {
            connection.cancel()
        }
    }

    private func readHeader(from connection: NWConnection) async -> HeaderRead {
        var buffer = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while buffer.count < Self.maxHeaderBytes {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    cont.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
                }
            }
            guard let chunk else { return .incomplete }
            buffer.append(chunk)
            if let end = buffer.range(of: delimiter)?.upperBound {
                return end <= Self.maxHeaderBytes ? .complete(Data(buffer.prefix(end))) : .tooLarge
            }
        }
        return .tooLarge
    }

    private func sendRaw(_ text: String, on connection: NWConnection) async {
        _ = await sendData(Data(text.utf8), on: connection)
    }

    private func sendData(_ data: Data, on connection: NWConnection) async -> Bool {
        let timeout = Self.startTimeout(on: connection)
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                connection.send(content: data, completion: .contentProcessed { error in
                    cont.resume(returning: error == nil)
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func startTimeout(on connection: NWConnection) -> Task<Void, Never> {
        Task.detached {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            connection.cancel()
        }
    }

    internal struct ParsedHttpRequest: Sendable {
        let method: String
        let path: String
        let rangeHeader: String?
    }

    internal static func parseHttpRequest(_ data: Data) -> ParsedHttpRequest? {
        guard data.count <= maxHeaderBytes, let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n") else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        let method = String(parts[0])
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?").first.map(String.init) ?? rawTarget

        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let name = line[..<colon].lowercased()
            if name == "range" {
                guard rangeHeader == nil else { return nil }
                rangeHeader = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return ParsedHttpRequest(method: method, path: path, rangeHeader: rangeHeader)
    }

    internal static func resolveByteRange(
        rangeHeader: String?,
        totalLength: Int64
    ) -> (start: Int64, end: Int64, isPartial: Bool)? {
        guard totalLength > 0 else { return nil }
        guard let rangeHeader else { return (0, totalLength - 1, false) }
        guard rangeHeader.lowercased().hasPrefix("bytes="), !rangeHeader.contains(",") else { return nil }
        let spec = String(rangeHeader.dropFirst(6))
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
