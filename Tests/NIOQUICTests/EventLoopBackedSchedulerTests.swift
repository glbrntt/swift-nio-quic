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

import NIOEmbedded
import Testing

@testable import NIOQUIC
@_spi(ProtocolProvider) @testable import SwiftNetwork

struct EventLoopBackedSchedulerTests {
    @available(anyAppleOS 26, *)
    private func reference(_ index: Int) -> TimerReference {
        TimerReference(index: index)
    }

    @available(anyAppleOS 26, *)
    private func withScheduler(
        _ body: (EventLoopBackedScheduler, EmbeddedEventLoop) throws -> Void
    ) throws {
        let loop = EmbeddedEventLoop()
        let scheduler = EventLoopBackedScheduler(eventLoop: loop)
        defer { try! loop.syncShutdownGracefully() }
        try body(scheduler, loop)
    }

    @available(anyAppleOS 26, *)
    @Test
    func taskRunsOnceItsDeadlinePasses() throws {
        try self.withScheduler { scheduler, loop in
            let counter = Counter()
            scheduler.schedule({ counter.increment() }, milliseconds: 100, reference: self.reference(0))

            loop.advanceTime(by: .milliseconds(99))
            #expect(counter.load() == 0)

            loop.advanceTime(by: .milliseconds(1))
            #expect(counter.load() == 1)

            // The task must not repeat.
            loop.advanceTime(by: .seconds(1))
            #expect(counter.load() == 1)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func reschedulingAReferenceCancelsTheTaskItReplaces() throws {
        try self.withScheduler { scheduler, loop in
            let first = Counter()
            let second = Counter()
            scheduler.schedule({ first.increment() }, milliseconds: 100, reference: self.reference(0))
            scheduler.schedule({ second.increment() }, milliseconds: 200, reference: self.reference(0))

            loop.advanceTime(by: .milliseconds(100))
            #expect(first.load() == 0)
            #expect(second.load() == 0)

            loop.advanceTime(by: .milliseconds(100))
            #expect(first.load() == 0)
            #expect(second.load() == 1)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func schedulingAReferenceAgainAfterItHasFiredRunsTheNewTask() throws {
        try self.withScheduler { scheduler, loop in
            let first = Counter()
            let second = Counter()
            scheduler.schedule({ first.increment() }, milliseconds: 100, reference: self.reference(0))
            loop.advanceTime(by: .milliseconds(100))
            #expect(first.load() == 1)

            scheduler.schedule({ second.increment() }, milliseconds: 100, reference: self.reference(0))
            loop.advanceTime(by: .milliseconds(100))
            #expect(first.load() == 1)
            #expect(second.load() == 1)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func unscheduledTaskDoesNotRun() throws {
        try self.withScheduler { scheduler, loop in
            let counter = Counter()
            scheduler.schedule({ counter.increment() }, milliseconds: 100, reference: self.reference(0))
            scheduler.unschedule(reference: self.reference(0))

            loop.advanceTime(by: .seconds(1))
            #expect(counter.load() == 0)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func referencesAreScheduledAndUnscheduledIndependently() throws {
        try self.withScheduler { scheduler, loop in
            let first = Counter()
            let second = Counter()
            scheduler.schedule({ first.increment() }, milliseconds: 100, reference: self.reference(0))
            scheduler.schedule({ second.increment() }, milliseconds: 100, reference: self.reference(1))
            scheduler.unschedule(reference: self.reference(1))

            loop.advanceTime(by: .milliseconds(100))
            #expect(first.load() == 1)
            #expect(second.load() == 0)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func unschedulingAnUnknownReferenceIsANoop() throws {
        try self.withScheduler { scheduler, _ in
            scheduler.unschedule(reference: self.reference(0))
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func schedulingOnAShutdownEventLoopIsIgnored() throws {
        let loop = EmbeddedEventLoop()
        let scheduler = EventLoopBackedScheduler(eventLoop: loop)
        try loop.syncShutdownGracefully()

        let counter = Counter()
        scheduler.schedule({ counter.increment() }, milliseconds: 100, reference: self.reference(0))
        loop.advanceTime(by: .seconds(1))
        #expect(counter.load() == 0)
    }

    @available(anyAppleOS 26, *)
    @Test
    func immediateTaskRunsOnTheEventLoop() throws {
        try self.withScheduler { scheduler, loop in
            let counter = Counter()
            scheduler.runImmediate { counter.increment() }
            #expect(counter.load() == 0)

            loop.run()
            #expect(counter.load() == 1)
        }
    }

    @available(anyAppleOS 26, *)
    @Test
    func runningInSchedulerReflectsTheEventLoop() throws {
        try self.withScheduler { scheduler, _ in
            // EmbeddedEventLoop is always "in" the event loop of the thread which created it.
            #expect(scheduler.runningInScheduler)
        }
    }
}
