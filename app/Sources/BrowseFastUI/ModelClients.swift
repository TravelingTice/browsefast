import Foundation

struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Claude Haiku over the Messages API, always answering in JSON that matches `schema`.
struct ClaudeClient {
    static let model = "claude-haiku-5-5"
    let apiKey: String

    struct Reply<T> {
        let value: T
        let raw: String
        let ms: Int
        let inputTokens: Int
        let outputTokens: Int
    }

    func json<T: Decodable>(_ type: T.Type, system: String, prompt: String, schema: [String: Any]) async throws -> Reply<T> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4000,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw AgentError("Claude: \(message)")
        }
        if json["stop_reason"] as? String == "refusal" { throw AgentError("Claude declined this request") }

        let text = (json["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        let usage = json["usage"] as? [String: Any]
        guard let value = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else {
            throw AgentError("Claude returned an unexpected answer: \(text.prefix(200))")
        }
        return Reply(value: value, raw: text, ms: ms,
                     inputTokens: usage?["input_tokens"] as? Int ?? 0,
                     outputTokens: usage?["output_tokens"] as? Int ?? 0)
    }
}

/// Jev (TypeSafe System One) answering a single choice question.
struct JevClient {
    static let model = "jev-latest"
    let apiKey: String

    struct Choice {
        let choice: String
        let confidence: Double
        let probabilities: [(option: String, p: Double)]
        let ms: Int
    }

    func choose(state: String, instructions: String, options: [(key: String, description: String)]) async throws -> Choice {
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let criteria = Dictionary(options.map { ($0.key, $0.description) }, uniquingKeysWith: { a, _ in a })
        let body: [String: Any] = [
            "model": Self.model,
            "state": state,
            "questions": ["action": ["type": "choice", "instructions": instructions, "criteria": criteria]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = json["detail"] as? [String: Any]
            throw AgentError("Jev: \(detail?["message"] as? String ?? "HTTP \(status)")")
        }
        guard let answer = (json["answers"] as? [String: Any])?["action"] as? [String: Any],
              let choice = answer["choice"] as? String else {
            throw AgentError("Jev returned an unexpected answer: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        let probabilities = (answer["probabilities"] as? [String: Double] ?? [:])
            .sorted { $0.value > $1.value }
            .map { (option: $0.key, p: $0.value) }
        return Choice(choice: choice, confidence: answer["confidence"] as? Double ?? 0, probabilities: probabilities, ms: ms)
    }
}
