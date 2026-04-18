import Foundation

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

enum OpenClawBridgeError: LocalizedError {
  case notConfigured
  case invalidURL
  case httpError(Int)
  case invalidResponse
  case missingOutputText

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "OpenClaw is not configured."
    case .invalidURL:
      return "Invalid OpenClaw gateway URL."
    case .httpError(let statusCode):
      return "OpenClaw returned HTTP \(statusCode)."
    case .invalidResponse:
      return "OpenClaw returned an invalid response."
    case .missingOutputText:
      return "OpenClaw returned no output text."
    }
  }
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: String]] = []
  private let maxHistoryTurns = 10

  private static let stableSessionKey = "agent:main:glass"

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.sessionKey = OpenClawBridge.stableSessionKey
  }

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (_, response) = try await pingSession.data(for: request)
      if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
        connectionState = .connected
        NSLog("[OpenClaw] Gateway reachable (HTTP %d)", http.statusCode)
      } else {
        connectionState = .unreachable("Unexpected response")
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[OpenClaw] Gateway unreachable: %@", error.localizedDescription)
    }
  }

  func resetSession() {
    conversationHistory = []
    NSLog("[OpenClaw] Session reset (key retained: %@)", sessionKey)
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    // Append the new user message to conversation history
    conversationHistory.append(["role": "user", "content": task])

    // Trim history to keep only the most recent turns (user+assistant pairs)
    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages in conversation", conversationHistory.count)

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        // Append assistant response to history for continuity
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }

  func analyzeImage(
    jpegData: Data,
    prompt: String
  ) async -> Result<String, Error> {
    let toolName = "analyze"
    lastToolCallStatus = .executing(toolName)

    guard GeminiConfig.isOpenClawConfigured else {
      return failAnalyzeRequest(with: OpenClawBridgeError.notConfigured, toolName: toolName)
    }

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/responses") else {
      return failAnalyzeRequest(with: OpenClawBridgeError.invalidURL, toolName: toolName)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "stream": false,
      "input": [
        [
          "type": "message",
          "role": "user",
          "content": [
            [
              "type": "input_text",
              "text": prompt
            ],
            [
              "type": "input_image",
              "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": jpegData.base64EncodedString()
              ]
            ]
          ]
        ]
      ]
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Image analysis failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        return failAnalyzeRequest(with: OpenClawBridgeError.httpError(code), toolName: toolName)
      }

      let text = try parseAnalyzeResponseText(from: data)
      NSLog("[OpenClaw] Image analysis result: %@", String(text.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(text)
    } catch {
      NSLog("[OpenClaw] Image analysis error: %@", error.localizedDescription)
      return failAnalyzeRequest(with: error, toolName: toolName)
    }
  }

  private func parseAnalyzeResponseText(from data: Data) throws -> String {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let output = json["output"] as? [[String: Any]],
          let firstOutput = output.first,
          let content = firstOutput["content"] as? [[String: Any]] else {
      throw OpenClawBridgeError.invalidResponse
    }

    if let outputText = content.first(where: { ($0["type"] as? String) == "output_text" }),
       let text = outputText["text"] as? String,
       !text.isEmpty {
      return text
    }

    if let text = content.compactMap({ $0["text"] as? String }).first(where: { !$0.isEmpty }) {
      return text
    }

    throw OpenClawBridgeError.missingOutputText
  }

  private func failAnalyzeRequest(
    with error: Error,
    toolName: String
  ) -> Result<String, Error> {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    lastToolCallStatus = .failed(toolName, message)
    return .failure(error)
  }
}
