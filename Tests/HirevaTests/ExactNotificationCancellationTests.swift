import Combine
import Foundation
import Testing
@testable import Hireva

struct ExactNotificationCancellationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func backgroundCancellationRemovesOnlyItsExactRegistration(explicit: Bool) async throws {
        let center = NotificationCenter()
        let name = Notification.Name("Hireva.OwnedObserverTest.\(UUID().uuidString)")
        let target = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let neighbor = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let box = BackgroundNotificationCancellationOwner()
        await box.install(center: center, name: name, receipt: target.continuation)
        let other = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            neighbor.continuation.yield(())
        }
        let otherCancellation = AppState.makeNotificationCancellation(observer: other, center: center)
        defer {
            otherCancellation.cancel()
            target.continuation.finish(); neighbor.continuation.finish()
        }
        var targetEvents = target.stream.makeAsyncIterator()
        var neighborEvents = neighbor.stream.makeAsyncIterator()
        center.post(name: name, object: nil)
        #expect(await targetEvents.next() != nil)
        #expect(await neighborEvents.next() != nil)
        if explicit { await box.cancel(); await box.cancel() }
        await box.release()
        // queue:nil delivery is synchronous; finish AFTER the actual post.
        // A leaked exact observer would leave a buffered value, not a timeout.
        center.post(name: name, object: nil)
        target.continuation.finish(); neighbor.continuation.finish()
        #expect(await targetEvents.next() == nil)
        #expect(await neighborEvents.next() != nil)
        #expect(await neighborEvents.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func backgroundReleaseUsesTheExactOriginalCenter(explicit: Bool) async throws {
        let ownedCenter = NotificationCenter()
        let otherCenter = NotificationCenter()
        let name = Notification.Name("Hireva.OwnedObserverCenterTest.\(UUID().uuidString)")
        let owned = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let other = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let box = BackgroundNotificationCancellationOwner()
        await box.install(center: ownedCenter, name: name, receipt: owned.continuation)
        let otherToken = otherCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
            other.continuation.yield(())
        }
        let otherCancellation = AppState.makeNotificationCancellation(observer: otherToken, center: otherCenter)
        defer {
            otherCancellation.cancel()
            owned.continuation.finish(); other.continuation.finish()
        }
        if explicit { await box.cancel() }
        await box.release()
        ownedCenter.post(name: name, object: nil)
        otherCenter.post(name: name, object: nil)
        owned.continuation.finish(); other.continuation.finish()
        var ownedEvents = owned.stream.makeAsyncIterator()
        var otherEvents = other.stream.makeAsyncIterator()
        #expect(await ownedEvents.next() == nil)
        #expect(await otherEvents.next() != nil)
        #expect(await otherEvents.next() == nil)
    }
}

private actor BackgroundNotificationCancellationOwner {
    private var cancellation: AnyCancellable?
    func install(center: NotificationCenter, name: Notification.Name,
        receipt: AsyncStream<Void>.Continuation) {
        let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in receipt.yield(()) }
        // The helper is NONISOLATED; its closure cannot inherit MainActor.
        cancellation = AppState.makeNotificationCancellation(observer: observer, center: center)
    }
    func cancel() { #expect(!Thread.isMainThread); cancellation?.cancel() }
    func release() { #expect(!Thread.isMainThread); cancellation = nil }
}
