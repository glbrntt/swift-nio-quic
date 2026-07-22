//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
@_spi(ProtocolProvider) @_spi(Essentials) import SwiftNetwork

@available(anyAppleOS 26, *)
struct ScheduledEntry {
    var handle: NIOScheduledCallback?
    var task: () -> Void
}

@available(anyAppleOS 26, *)
extension ScheduledEntry: NIOScheduledCallbackHandler {
    func handleScheduledCallback(eventLoop: some NIOCore.EventLoop) {
        self.task()
    }
}

@available(anyAppleOS 26, *)
final class EventLoopBackedScheduler: NetworkContext.Scheduler, CustomStringConvertible {
    internal var description: String { "EventLoopBackedScheduler" }

    internal var runningInScheduler: Bool {
        self.eventLoop.inEventLoop
    }

    private var scheduledTasks: [SwiftNetwork.TimerReference: ScheduledEntry] = [:]
    private let eventLoop: any EventLoop
    internal init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    private struct UnsafeTransfer: @unchecked Sendable {
        var wrappedValue: () -> Void
        init(_ wrappedValue: @escaping (() -> Void)) {
            self.wrappedValue = wrappedValue
        }
    }

    func runImmediate(_ task: @escaping (() -> Void)) {
        if self.eventLoop.inEventLoop {
            self.eventLoop.assumeIsolatedUnsafeUnchecked().execute(task)
        } else {
            // Remove once this has landed: https://github.com/apple/swift-network-evolution/pull/36
            let transfer = UnsafeTransfer(task)
            self.eventLoop.execute {
                let value = transfer.wrappedValue
                value()
            }
        }
    }

    func schedule(
        _ task: @escaping (() -> Void),
        milliseconds: Int64,
        reference: SwiftNetwork.TimerReference
    ) {
        // Get the isolated EL now: check that the caller is on the right EL _before_ modifying
        // any state.
        let isolatedEventLoop = self.eventLoop.assumeIsolated()

        self.scheduledTasks.withEntry(
            for: reference,
            default: ScheduledEntry(task: task)
        ) { entry in
            // Cancel the existing task, if one is present.
            let handle = entry.handle.take()
            handle?.cancel()

            // The entry may be pre-existing: it must run the task being scheduled now, not the
            // task it was created with.
            entry.task = task

            // Scheduling can fail if the EL is shutdown: swallow the error.
            entry.handle = try? isolatedEventLoop.scheduleCallback(
                in: .milliseconds(milliseconds),
                handler: entry
            )
        }
    }

    func unschedule(reference: SwiftNetwork.TimerReference) {
        if let removedEntry = self.scheduledTasks.removeValue(forKey: reference) {
            removedEntry.handle?.cancel()
        }
    }
}

@available(anyAppleOS 26, *)
extension [TimerReference: ScheduledEntry] {
    mutating func withEntry(
        for reference: SwiftNetwork.TimerReference,
        default: @autoclosure () -> ScheduledEntry,
        execute body: (inout Value) -> Void
    ) {
        body(&self[reference, default: `default`()])
    }
}
