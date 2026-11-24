import Foundation
import Network

/// Tracks unmetered Wi-Fi vs metered cellular / Low Data Mode reactively via `NWPathMonitor`
/// and combines with `PreloadMode` to safely scale background prefetching on mobile connections.
public final class NetworkPolicy: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "me.animeheaven.ios.networkpolicy", qos: .utility)
    private let lock = NSLock()
    private var _isMetered: Bool = false
    private var _isConnected: Bool = true
    private let preloadModeProvider: @Sendable () -> PreloadMode

    public init(preloadModeProvider: @escaping @Sendable () -> PreloadMode) {
        self.preloadModeProvider = preloadModeProvider
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._isMetered = path.isExpensive || path.isConstrained
            self._isConnected = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
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
        let userMode = preloadModeProvider()
        if userMode == .aggressive && isMetered {
            return .balanced
        }
        return userMode
    }

    public var allowBackgroundVideoPreload: Bool {
        effectiveMode == .aggressive && !isMetered
    }

    public var nextEpisodeVideoBytes: Int64 {
        switch effectiveMode {
        case .aggressive: return isMetered ? 0 : 8 * 1024 * 1024
        case .balanced: return 0
        case .dataSaver: return 0
        }
    }

    public var continueWatchingVideoBytes: Int64 {
        switch effectiveMode {
        case .aggressive: return isMetered ? 0 : 2 * 1024 * 1024
        case .balanced: return 0
        case .dataSaver: return 0
        }
    }

    public var allowBackgroundCatalogPreload: Bool {
        effectiveMode != .dataSaver
    }
}
