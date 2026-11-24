import Foundation

/// Thread-safe, bounded access-ordered LRU cache.
public final class LruCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        weak var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    public let maxEntries: Int
    private let lock = NSLock()
    private var map: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?

    public init(maxEntries: Int) {
        self.maxEntries = max(1, maxEntries)
    }

    deinit {
        clear()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return map.count
    }

    public func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    public func set(_ key: Key, value: Value) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = map[key] {
            existing.value = value
            moveToHead(existing)
            return
        }
        let node = Node(key: key, value: value)
        map[key] = node
        insertAtHead(node)
        while map.count > maxEntries, let lru = tail {
            removeNode(lru)
            map.removeValue(forKey: lru.key)
        }
    }

    public func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map.removeValue(forKey: key) else { return }
        removeNode(node)
    }

    public func clear() {
        lock.lock()
        var node = head
        // Release arbitrary cached values after unlocking, including values with custom deinit.
        var removed = [Key: Node]()
        swap(&removed, &map)
        head = nil
        tail = nil
        lock.unlock()
        while let current = node {
            node = current.next
            current.next = nil
            current.prev = nil
        }
    }

    public func allKeys() -> [Key] {
        lock.lock()
        defer { lock.unlock() }
        return Array(map.keys)
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func removeNode(_ node: Node) {
        let p = node.prev
        let n = node.next
        if let p {
            p.next = n
        } else {
            head = n
        }
        if let n {
            n.prev = p
        } else {
            tail = p
        }
        node.prev = nil
        node.next = nil
    }

    private func moveToHead(_ node: Node) {
        if head === node { return }
        removeNode(node)
        insertAtHead(node)
    }
}
