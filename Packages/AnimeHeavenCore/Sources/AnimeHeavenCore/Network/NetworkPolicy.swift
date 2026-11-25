import Foundation
import Network

/// Tracks unmetered Wi-Fi/Ethernet vs metered cellular / Low Data Mode reactively via
/// `NWPathMonitor`. Strictly disables all background video preloading on metered networks.
public final class NetworkPolicy: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "me.animeheaven.ios.networkpolicy", qos: .utility)
    private let lock = NSLock()
    private var _isMetered: Bool = false
    private var _isConnected: Bool = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private let preloadModeProvider: @Sendable () -> PreloadMode

    public init(preloadModeProvider: @escaping @Sendable () -> PreloadMode) {
        self.preloadModeProvider = preloadModeProvider
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let metered = path.isExpensive || path.isConstrained
            let connected = path.status == .satisfied
            self.lock.lock()
            let wasUnmetered = !self._isMetered && self._isConnected
            self._isMetered = metered
            self._isConnected = connected
            let isUnmeteredNow = !metered && connected
            let activeContinuations = Array(self.continuations.values)
            self.lock.unlock()

            if isUnmeteredNow != wasUnmetered {
                for cont in activeContinuations {
                    cont.yield(isUnmeteredNow)
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
        lock.lock()
        let active = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for cont in active { cont.finish() }
    }

    public static func resolveEffectiveMode(configured: PreloadMode, metered: Bool) -> PreloadMode {
        metered ? .dataSaver : configured
    }

    public func observeUnmeteredTransitions() -> AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public var isMetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMetered
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    public var effectiveMode: PreloadMode {
        Self.resolveEffectiveMode(configured: preloadModeProvider(), metered: isMetered)
    }

    public var allowBackgroundVideoPreload: Bool {
        effectiveMode != .dataSaver && !isMetered
    }

    public var allowBackgroundCatalogPreload: Bool {
        effectiveMode != .dataSaver
    }

    public var maxContinueWatchingCount: Int {
        switch effectiveMode {
        case .aggressive: return 15
        case .balanced: return 5
        case .dataSaver: return 0
        }
    }

    public func continueVideoBytes(index: Int) -> Int64 {
        guard !isMetered else { return 0 }
        switch effectiveMode {
        case .aggressive:
            if index == 0 { return 8 * 1024 * 1024 }
            if index <= 2 { return 6 * 1024 * 1024 }
            if index < 15 { return 5 * 1024 * 1024 }
            return 0
        case .balanced:
            if index == 0 { return 4 * 1024 * 1024 }
            if index <= 2 { return 3 * 1024 * 1024 }
            return 0
        case .dataSaver:
            return 0
        }
    }

    public var continueWatchingVideoBytes: Int64 {
        continueVideoBytes(index: 0)
    }

    public var bannerVideoCount: Int {
        switch effectiveMode {
        case .aggressive: return 5
        case .balanced: return 1
        case .dataSaver: return 0
        }
    }

    public func bannerVideoBytes(index: Int) -> Int64 {
        guard !isMetered else { return 0 }
        switch effectiveMode {
        case .aggressive: return index == 0 ? 6 * 1024 * 1024 : 5 * 1024 * 1024
        case .balanced: return index == 0 ? 3 * 1024 * 1024 : 0
        case .dataSaver: return 0
        }
    }

    public var bookmarkDetailCount: Int {
        switch effectiveMode {
        case .aggressive: return 15
        case .balanced: return 3
        case .dataSaver: return 0
        }
    }

    public var bookmarkVideoCount: Int {
        effectiveMode == .aggressive && !isMetered ? 15 : 0
    }

    public var bookmarkVideoBytes: Int64 {
        effectiveMode == .aggressive && !isMetered ? 4608 * 1024 : 0
    }

    public var homePopularDetailCount: Int {
        switch effectiveMode {
        case .aggressive: return 12
        case .balanced: return 4
        case .dataSaver: return 0
        }
    }

    public var homeScheduleDetailCount: Int {
        switch effectiveMode {
        case .aggressive: return 24
        case .balanced: return 4
        case .dataSaver: return 0
        }
    }

    public var homeShowVideoBytes: Int64 {
        effectiveMode == .aggressive && !isMetered ? 4 * 1024 * 1024 : 0
    }

    public var catalogDetailCount: Int {
        switch effectiveMode {
        case .aggressive: return 10
        case .balanced: return 3
        case .dataSaver: return 0
        }
    }

    public var catalogVideoCount: Int {
        effectiveMode == .aggressive && !isMetered ? 8 : 0
    }

    public var detailPrimaryVideoBytes: Int64 {
        guard !isMetered else { return 0 }
        switch effectiveMode {
        case .aggressive: return 8 * 1024 * 1024
        case .balanced: return 4 * 1024 * 1024
        case .dataSaver: return 0
        }
    }

    public var detailFollowupVideoBytes: Int64 {
        effectiveMode == .aggressive && !isMetered ? 4 * 1024 * 1024 : 0
    }

    public var nextEpisodeInitialBytes: Int64 {
        guard !isMetered else { return 0 }
        switch effectiveMode {
        case .aggressive: return 6 * 1024 * 1024
        case .balanced: return 4 * 1024 * 1024
        case .dataSaver: return 0
        }
    }

    public var nextEpisodeEscalatedBytes: Int64 {
        guard !isMetered else { return 0 }
        switch effectiveMode {
        case .aggressive: return 20 * 1024 * 1024
        case .balanced: return 10 * 1024 * 1024
        case .dataSaver: return 0
        }
    }

    public var nextEpisodeVideoBytes: Int64 {
        nextEpisodeInitialBytes
    }
}
