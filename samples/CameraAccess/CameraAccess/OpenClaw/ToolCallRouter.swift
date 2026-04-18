import Foundation

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private let executeHandler: (String) async -> ToolResult
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var inFlightToolNames: [String: String] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3

  init(
    bridge: OpenClawBridge,
    executeHandler: @escaping (String) async -> ToolResult
  ) {
    self.bridge = bridge
    self.executeHandler = executeHandler
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    // Circuit breaker: stop sending tool calls after repeated failures
    if consecutiveFailures >= maxConsecutiveFailures {
      NSLog("[ToolCall] Circuit breaker open (%d consecutive failures), rejecting %@",
            consecutiveFailures, callId)
      let errorResult: ToolResult = .failure(
        "Tool execution is temporarily unavailable after \(consecutiveFailures) consecutive failures. " +
        "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
      )
      let response = buildToolResponse(callId: callId, name: callName, result: errorResult)
      sendResponse(response)
      return
    }

    let task = Task { @MainActor in
      let result: ToolResult

      switch callName {
      case "execute":
        let taskDesc = (call.args["task"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskDesc.isEmpty else {
          let errorResult: ToolResult = .failure("Missing homework question for execute.")
          self.bridge.lastToolCallStatus = .failed(callName, "Missing homework question")
          sendResponse(self.buildToolResponse(callId: callId, name: callName, result: errorResult))
          self.inFlightTasks.removeValue(forKey: callId)
          self.inFlightToolNames.removeValue(forKey: callId)
          return
        }
        result = await executeHandler(taskDesc)
      default:
        let message = "Unsupported tool: \(callName)"
        self.bridge.lastToolCallStatus = .failed(callName, message)
        result = .failure(message)
      }

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      switch result {
      case .success:
        self.consecutiveFailures = 0
      case .failure:
        self.consecutiveFailures += 1
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
      self.inFlightToolNames.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
    inFlightToolNames[callId] = callName
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
        let toolName = inFlightToolNames.removeValue(forKey: id) ?? "unknown"
        bridge.lastToolCallStatus = .cancelled(toolName)
      }
    }
  }

  /// Cancel all in-flight tool calls (on session stop)
  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
    inFlightToolNames.removeAll()
    consecutiveFailures = 0
  }

  // MARK: - Private

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
