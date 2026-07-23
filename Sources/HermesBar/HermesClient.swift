import Foundation

// A Hermes session as listed by GET /api/sessions (shared with Desktop).
struct HermesSession: Identifiable, Equatable {
    let id: String
    let title: String
    var updated: String = ""
}

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

    // Blocking web search via Tavily (call on a background thread). Returns a
    // compact results block to prepend to the prompt, so ANY model gets fresh
    // info — independent of provider. Returns nil on failure / no key.
    func webSearchBlocking(query: String, apiKey: String) -> String? {
        guard !apiKey.isEmpty, !query.isEmpty,
              let url = URL(string: "https://api.tavily.com/search") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // include_answer → Tavily returns a concise synthesized answer; we inject
        // that (not 5 raw pages) so the prompt stays lean and on-topic.
        let payload: [String: Any] = ["api_key": apiKey, "query": query,
                                      "max_results": 4, "search_depth": "advanced",
                                      "include_answer": true]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        var out: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var s = "[Web search — use only what's relevant to the question]\n"
            if let answer = json["answer"] as? String, !answer.isEmpty {
                s += "Summary: \(answer)\n"
            }
            if let results = json["results"] as? [[String: Any]], !results.isEmpty {
                s += "Sources:\n"
                for r in results.prefix(4) {
                    let title = (r["title"] as? String) ?? ""
                    let link = (r["url"] as? String) ?? ""
                    let snippet = String(((r["content"] as? String) ?? "").prefix(120))
                    s += "- \(title): \(snippet) (\(link))\n"
                }
            }
            let trimmed = String(s.prefix(1200))
            out = trimmed.count > 40 ? trimmed : nil   // ignore empty/near-empty blocks
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        return out
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

    // List sessions from the active gateway (GET /api/sessions). These are shared
    // with Hermes Desktop when both point at the same gateway, so the panel can
    // adopt a Desktop conversation and continue it. Defensive about response shape.
    func listSessions(host: String, apiKey: String, _ completion: @escaping ([HermesSession]) -> Void) {
        guard let url = URL(string: "\(host)/api/sessions?limit=40") else {
            DispatchQueue.main.async { completion([]) }; return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var out: [HermesSession] = []
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) {
                let arr: [[String: Any]]
                if let a = json as? [[String: Any]] { arr = a }
                else if let o = json as? [String: Any] {
                    arr = (o["sessions"] as? [[String: Any]]) ?? (o["data"] as? [[String: Any]])
                        ?? (o["items"] as? [[String: Any]]) ?? (o["results"] as? [[String: Any]]) ?? []
                } else { arr = [] }
                for s in arr {
                    let id = (s["id"] as? String) ?? (s["session_id"] as? String) ?? (s["sessionId"] as? String) ?? ""
                    guard !id.isEmpty else { continue }
                    let title = (s["title"] as? String) ?? (s["name"] as? String) ?? id
                    let updated = (s["updated_at"] as? String) ?? (s["updated"] as? String) ?? ""
                    out.append(HermesSession(id: id, title: title, updated: updated))
                }
            }
            DispatchQueue.main.async { completion(out) }
        }.resume()
    }

    // Set a human title on a Hermes session (shows in Desktop's session list).
    // Fire-and-forget PATCH /api/sessions/{id}. Best-effort — ignores failures.
    func setSessionTitle(host: String?, sessionId: String, title: String) {
        let useHost = host ?? Settings.shared.deepHost()
        let encodedId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        guard !title.isEmpty, let url = URL(string: "\(useHost)/api/sessions/\(encodedId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Settings.shared.deepKey())", forHTTPHeaderField: "Authorization")
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
                        var collected = ""
                        for try await line in bytes.lines {
                            collected += line
                            if collected.count > 600 { break }
                        }
                        let errBody = String(collected.prefix(600))
                        let code = http.statusCode
                        await MainActor.run { onDone(ClientError.badStatus(code, errBody)) }
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
