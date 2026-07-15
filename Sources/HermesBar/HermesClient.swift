import Foundation

// Talks to the local Hermes API server (`hermes gateway`) using the
// OpenAI-compatible /v1/chat/completions endpoint. Sends the FULL conversation
// each turn (so Hermes has context), streams the reply, and can be cancelled.
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

    // Fetch the available model ids from an OpenAI-compatible provider (GET /v1/models).
    func fetchModels(host: String, apiKey: String, _ completion: @escaping ([String]) -> Void) {
        let base = host.hasSuffix("/v1") ? host : "\(host)/v1"
        guard let url = URL(string: "\(base)/models") else { DispatchQueue.main.async { completion([]) }; return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var ids: [String] = []
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["data"] as? [[String: Any]] {
                ids = arr.compactMap { $0["id"] as? String }
            }
            DispatchQueue.main.async { completion(ids.sorted()) }
        }.resume()
    }

    // Set a human title on a Hermes session (shows in Desktop's session list).
    // Fire-and-forget PATCH /api/sessions/{id}. Best-effort — ignores failures.
    func setSessionTitle(host: String?, sessionId: String, title: String) {
        let useHost = host ?? Settings.shared.host
        let encodedId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        guard !title.isEmpty, let url = URL(string: "\(useHost)/api/sessions/\(encodedId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Settings.shared.resolvedAPIKey())", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title])
        URLSession.shared.dataTask(with: req).resume()
    }

    // `conversation` is the turns to send. In server-managed mode this is just the
    // new user turn (Hermes loads prior history from state.db via the session
    // header); otherwise it's the full history. `sessionId`, when set, is sent as
    // `X-Hermes-Session-Id` so Hermes treats the exchange as a first-class session.
    private func makeRequest(host: String,
                             conversation: [[String: Any]],
                             reasoningEffort: String?,
                             stream: Bool,
                             sessionId: String?,
                             includeSystem: Bool,
                             apiKey: String?,
                             model: String,
                             webSearch: Bool) -> URLRequest? {
        // `host` may already include the /v1 path (direct providers); only append
        // the endpoint, not a duplicate /v1.
        let base = host.hasSuffix("/v1") ? host : "\(host)/v1"
        guard let url = URL(string: "\(base)/chat/completions") else { return nil }

        let systemPrompt = """
        Format every answer as a rich GitHub-Flavored Markdown message:
        - Start complex answers with a short ## heading and a one-line summary.
        - For tabular data use a REAL Markdown table INCLUDING the header-separator row (| A | B |\\n|---|---|).
        - For steps / to-dos use task checklists: "- [x] done item" and "- [ ] pending item".
        - Put code and shell commands inside fenced code blocks (```lang ... ```).
        - Use bold and lists where they improve clarity. Do NOT use raw HTML.
        - Keep prose in Arabic when the user writes in Arabic.
        """

        var messages: [[String: Any]] = []
        if includeSystem { messages.append(["role": "system", "content": systemPrompt]) }
        messages.append(contentsOf: conversation)

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream
        ]
        if let effort = reasoningEffort, !effort.isEmpty {
            payload["reasoning_effort"] = effort
        }
        if webSearch {
            payload["plugins"] = [["id": "web"]]   // OpenRouter web-search plugin
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let auth = (apiKey?.isEmpty == false ? apiKey! : Settings.shared.resolvedAPIKey())
        req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        if let sid = sessionId, !sid.isEmpty {
            req.setValue(sid, forHTTPHeaderField: "X-Hermes-Session-Id")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return req
    }

    @discardableResult
    func askStream(host: String? = nil,
                   conversation: [[String: Any]],
                   reasoningEffort: String? = nil,
                   sessionId: String? = nil,
                   includeSystem: Bool = true,
                   apiKey: String? = nil,
                   model: String = "hermes-agent",
                   webSearch: Bool = false,
                   onDelta: @escaping (String) -> Void,
                   onSession: ((String) -> Void)? = nil,
                   onDone: @escaping (Error?) -> Void) -> Task<Void, Never> {

        let useHost = host ?? Settings.shared.host
        guard let req = makeRequest(host: useHost,
                                    conversation: conversation,
                                    reasoningEffort: reasoningEffort,
                                    stream: true,
                                    sessionId: sessionId,
                                    includeSystem: includeSystem,
                                    apiKey: apiKey,
                                    model: model,
                                    webSearch: webSearch) else {
            DispatchQueue.main.async { onDone(ClientError.notReachable) }
            return Task {}
        }

        return Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                if let http = response as? HTTPURLResponse {
                    if let sid = http.value(forHTTPHeaderField: "X-Hermes-Session-Id"), !sid.isEmpty {
                        await MainActor.run { onSession?(sid) }
                    }
                    if !(200...299).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 600 { break }
                        }
                        await MainActor.run { onDone(ClientError.badStatus(http.statusCode, String(body.prefix(600)))) }
                        return
                    }
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
