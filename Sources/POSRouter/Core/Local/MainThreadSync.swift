import Foundation

/// Runs `work` on the main thread and returns its result synchronously. UIKit APIs such as
/// `UIApplication.shared` / `canOpenURL(_:)` must be touched on the main thread; a POS integrator
/// may call `pay()` / `connect()` from a background queue, so these hops keep those accesses safe
/// without deadlocking when the caller is already on main.
@inline(__always)
func onMainSync<T>(_ work: () -> T) -> T {
    if Thread.isMainThread { return work() }
    return DispatchQueue.main.sync(execute: work)
}
