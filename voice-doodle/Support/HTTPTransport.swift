import Foundation

extension URLRequest {
    /// Bearer auth + Content-Type + per-request extra headers.
    /// Shared by the OpenAI-compatible and MiMo clients — header
    /// application order is identical in both.
    mutating func applyAuth(apiKey: String, extraHeaders: [HTTPHeader]) {
        setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        for header in extraHeaders {
            setValue(header.value, forHTTPHeaderField: header.name)
        }
    }
}

enum HTTPTransport {
    /// URLError / CancellationError → VDError (shared transport mapping).
    /// Per-client httpStatus and body-cap handling stays client-local —
    /// MiMo passes body:nil, OpenAI truncates; those behaviors are preserved.
    static func mapTransportError(_ error: Error) -> VDError {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network(urlError.localizedDescription)
        }
        if error is CancellationError { return .timeout }
        return .network(String(describing: error))
    }
}
