import Foundation

// Talks to the local Hermes API server (`hermes gateway`) using the
// OpenAI-compatible /v1/chat/completions endpoint. Supports inline images,
// per-image detail, a reasoning-effort level, a host override (for Fast/Quality
// profiles), and streaming.
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

    private func makeRequest(host: String,
                             question: String,
                             imageDataURLs: [String],
                             imageDetail: String,
                             reasoningEffort: String?,
                             stream: Bool) -> URLRequest? {
        guard let url = URL(string: "\(host)/v1/chat/completions") else { return nil }

        var content: [[String: Any]] = [["type": "text", "text": question]]
        for durl in imageDataURLs {
            content.append([
                "type": "image_url",
                "image_url": ["url": durl, "detail": imageDetail]
            ])
        }

        var payload: [String: Any] = [
            "model": "hermes-agent",
            "messages": [["role": "user", "content": content]],
            "stream": stream
        ]
        if let effort = reasoningEffort, !effort.isEmpty {
            payload["reasoning_effort"] = effort
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(Settings.shared.resolvedAPIKey())", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return req
    }

    // Returns the streaming Task so the caller can cancel it (Stop button).
    @discardableResult
    func askStream(host: String? = nil,
                   question: String,
                   imageDataURLs: [String] = [],
                   imageDetail: String = "high",
                   reasoningEffort: String? = nil,
                   onDelta: @escaping (String) -> Void,
                   onDone: @escaping (Error?) -> Void) -> Task<Void, Never> {

        let useHost = host ?? Settings.shared.host
        guard let req = makeRequest(host: useHost,
                                    question: question,
                                    imageDataURLs: imageDataURLs,
                                    imageDetail: imageDetail,
                                    reasoningEffort: reasoningEffort,
                                    stream: true) else {
            DispatchQueue.main.async { onDone(ClientError.notReachable) }
            return Task {}
        }

        return Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    await MainActor.run { onDone(ClientError.badStatus(http.statusCode, "")) }
                    return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    if let data = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let delta = choices.first?["delta"] as? [String: Any],
                       let piece = delta["content"] as? String, !piece.isEmpty {
                        await MainActor.run { onDelta(piece) }
                    }
                }
                await MainActor.run { onDone(nil) }
            } catch {
                if Task.isCancelled {
                    await MainActor.run { onDone(nil) }
                } else {
                    await MainActor.run { onDone(ClientError.notReachable) }
                }
            }
        }
    }
}
