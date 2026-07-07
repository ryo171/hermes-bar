import Foundation

// Talks to the local Hermes API server (`hermes gateway`) using the
// OpenAI-compatible /v1/chat/completions endpoint, with an optional inline
// screenshot as documented by Hermes Agent.
final class HermesClient {
    static let shared = HermesClient()

    enum ClientError: LocalizedError {
        case notReachable
        case badStatus(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notReachable: return "Can't reach Hermes at localhost. Is `hermes gateway` running?"
            case .badStatus(let code, let body): return "Hermes returned \(code): \(body)"
            case .badResponse: return "Unexpected response from Hermes."
            }
        }
    }

    // Health check against GET /v1/health.
    func health(_ completion: @escaping (Bool) -> Void) {
        let s = Settings.shared
        guard let url = URL(string: "\(s.host)/v1/health") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    // Sends a question plus an optional base64 PNG screenshot; returns the reply.
    func ask(question: String,
             screenshotBase64: String?,
             completion: @escaping (Result<String, Error>) -> Void) {

        let s = Settings.shared
        guard let url = URL(string: "\(s.host)/v1/chat/completions") else {
            DispatchQueue.main.async { completion(.failure(ClientError.notReachable)) }
            return
        }

        // Build the multimodal content array.
        var content: [[String: Any]] = [["type": "text", "text": question]]
        if let b64 = screenshotBase64 {
            content.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/png;base64,\(b64)",
                    "detail": "high"
                ]
            ])
        }

        let payload: [String: Any] = [
            "model": "hermes-agent",
            "messages": [["role": "user", "content": content]],
            "stream": false
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(s.resolvedAPIKey())", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { data, response, error in
            func finish(_ r: Result<String, Error>) {
                DispatchQueue.main.async { completion(r) }
            }
            if error != nil {
                finish(.failure(ClientError.notReachable))
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                finish(.failure(ClientError.badResponse))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                finish(.failure(ClientError.badStatus(http.statusCode, body)))
                return
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let text = message["content"] as? String
            else {
                finish(.failure(ClientError.badResponse))
                return
            }
            finish(.success(text))
        }.resume()
    }
}
