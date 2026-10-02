//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Locked.swift
//  Starscream
//
//  Licensed under the Apache License, Version 2.0.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation

/// Back-deployable storage for state that is shared by callback-based networking APIs.
///
/// `Synchronization.Mutex` is not available on Starscream's iOS 15 deployment target. This
/// wrapper confines the reusable unchecked storage boundary: `value` is private, and every read
/// or mutation is performed while `lock` is held. Callers must not let an `inout` reference to the
/// protected value escape the closure.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&value)
    }
}

struct WeakReference<Object> {
    private weak var object: AnyObject?

    var value: Object? {
        object as? Object
    }

    init(_ value: Object? = nil) {
        object = value as AnyObject?
    }
}
