import Foundation

// Each check lists the provider's models: it needs a valid key but uses no tokens.
// Returns nil when the key works, otherwise a message to show under the field.
enum KeyValidator {
    static func checkClaude(_ key: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return await check(request, service: "Anthropic")
    }

    static func checkTypeSafe(_ key: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await check(request, service: "TypeSafe")
    }

    private static func check(_ request: URLRequest, service: String) async -> String? {
        var request = request
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200...299, 429:
                return nil // 429 = rate limited, which still means the key was accepted
            case 401, 403:
                return "\(service) didn't accept this key. Check that you copied all of it."
            case let code:
                if let message = errorMessage(in: data) { return "\(service): \(message)" }
                return "\(service) returned an error (HTTP \(code)). Try again in a moment."
            }
        } catch {
            return "Couldn't reach \(service). Check your internet connection."
        }
    }

    // Anthropic nests it under "error", TypeSafe under "detail".
    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["error", "detail"] {
            if let message = (json[key] as? [String: Any])?["message"] as? String { return message }
        }
        return json["message"] as? String
    }
}
