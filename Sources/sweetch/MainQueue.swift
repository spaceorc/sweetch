import Foundation

/// Carbon's Text Input Sources API is main-queue-only on modern macOS: HIToolbox runs
/// `dispatch_assert_queue` inside `TISCreateInputSourceList`, and a call from anywhere else
/// traps the whole process with SIGTRAP. It doesn't fire on every call — a cached source
/// list is served from any thread — which is why the convert path got away with it for a
/// long time and then killed the app.
///
/// Every TIS call funnels through here.
///
/// Deadlock note: `sync` is only ever reached from background work that the main thread is
/// not waiting on (the convert queue, LLM tasks). Never call it from a path the main thread
/// blocks on.
enum MainQueue {
    static func sync<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
}
