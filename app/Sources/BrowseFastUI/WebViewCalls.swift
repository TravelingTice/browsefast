import Foundation
import WebKit

/// Every call into a page goes through here so it can't hang the agent: WebKit's JavaScript calls can't be
/// cancelled and sometimes never return (pop-ups, pages navigating away mid-call). These give up after a
/// timeout, or as soon as the run is stopped.
extension WKWebView {
    func js(_ script: String, timeout: Double = 10) async throws -> Any? {
        try await withDeadline(timeout, what: "reading the page") { try await self.evaluateJavaScript(script) }
    }

    func asyncJS(_ body: String, timeout: Double = 10) async throws -> Any? {
        try await withDeadline(timeout, what: "waiting for the page") {
            try await self.callAsyncJavaScript(body, contentWorld: .page)
        }
    }
}

@MainActor
private func withDeadline(_ seconds: Double, what: String, _ work: @escaping @MainActor () async throws -> Any?) async throws -> Any? {
    final class Once: @unchecked Sendable {
        var continuation: CheckedContinuation<Any?, Error>?
        @MainActor func resume(_ result: Result<Any?, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
    let once = Once()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            once.continuation = continuation
            // Unstructured on purpose: a hung WebKit call can't be awaited away, so it's simply abandoned.
            Task { @MainActor in
                do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(.failure(AgentError("Timed out \(what) after \(Int(seconds)) seconds")))
            }
        }
    } onCancel: {
        Task { @MainActor in once.resume(.failure(CancellationError())) }
    }
}
