import Foundation
import Combine

@MainActor
final class QuestionCenter: ObservableObject {
    struct Option: Identifiable {
        let id = UUID()
        let label: String
        let detail: String
    }

    struct SubQuestion: Identifiable {
        let id = UUID()
        /// The original question's identity from `toolInput["questions"][n]`:
        /// its own `"id"` field if present, otherwise the index within the
        /// source `questions` array. Included in the combined answer text
        /// (via `header`) so a multi-question response stays legible to the
        /// agent reading it back.
        let sourceQuestionID: String
        let prompt: String
        let header: String
        let options: [Option]
        /// From the source question's own `"multiSelect"` field
        /// (`AskUserQuestion`'s schema). When true, `AgentQuestionView`
        /// renders toggleable checkboxes instead of single-shot choice
        /// buttons — see its `multiSelectView`.
        let isMultiSelect: Bool
    }

    struct Request: Identifiable {
        let id = UUID()
        let agent: AgentKind
        let sessionID: String
        /// Always at least one entry. A single `HookEvent`/`SocketConnection`
        /// backs the whole batch — see `resolve(_:answers:)` for why this
        /// must be answered as one unit rather than per sub-question.
        let questions: [SubQuestion]
        let connection: SocketConnection?
        /// Used by `AttentionCenter` to sort/tie-break the unified attention
        /// list — see its doc comment. Not read anywhere in this file.
        let occurredAt: Date

        var prompt: String { questions.first?.prompt ?? "" }
    }

    @Published private(set) var queue: [Request] = []

    func enqueue(_ event: HookEvent) {
        let agent = (event.toolInput["agent"] as? String).flatMap(AgentKind.init(rawValue:))
            ?? (event.toolName == "request_user_input" ? .codex : .claude)
        let questions = (event.toolInput["questions"] as? [[String: Any]]) ?? []

        guard !questions.isEmpty else {
            // Fall back to a single synthetic question built from the
            // top-level notification message (e.g. PermissionRequest-style
            // notifications that never populate `questions`).
            let sub = SubQuestion(
                sourceQuestionID: "0",
                prompt: (event.toolInput["message"] as? String)
                    ?? String(localized: "question.fallbackPrompt", defaultValue: "Agent needs your input"),
                header: String(localized: "question.fallbackHeader", defaultValue: "Agent asks"),
                options: [],
                isMultiSelect: false
            )
            let request = Request(agent: agent, sessionID: event.sessionId, questions: [sub], connection: event.connection, occurredAt: Date())
            queue = queue + [request]
            return
        }

        let subQuestions: [SubQuestion] = questions.enumerated().map { index, question in
            let prompt = (question["question"] as? String)
                ?? String(localized: "question.fallbackPrompt", defaultValue: "Agent needs your input")
            let header = (question["header"] as? String) ?? String(localized: "question.fallbackHeader", defaultValue: "Agent asks")
            let options = ((question["options"] as? [[String: Any]]) ?? []).map {
                Option(
                    label: ($0["label"] as? String) ?? String(localized: "question.fallbackOptionLabel", defaultValue: "Option"),
                    detail: ($0["description"] as? String) ?? ""
                )
            }
            let sourceID = (question["id"] as? String)
                ?? (question["id"] as? Int).map(String.init)
                ?? String(index)
            let isMultiSelect = (question["multiSelect"] as? Bool) ?? false
            return SubQuestion(sourceQuestionID: sourceID, prompt: prompt, header: header, options: options, isMultiSelect: isMultiSelect)
        }
        let request = Request(agent: agent, sessionID: event.sessionId, questions: subQuestions, connection: event.connection, occurredAt: Date())
        queue = queue + [request]
    }

    /// A `Request`'s `connection` is shared by every sub-question in its
    /// batch (one hook invocation = one socket connection = one response
    /// line the bridge process reads before exiting — see
    /// `SocketConnection.respond(json:)`'s one-shot `isClosed` guard). So
    /// this must only ever be called once per `Request`, with every
    /// sub-question's answer collected first — never once per sub-question,
    /// which would silently drop every answer after the first.
    func resolve(_ id: UUID, answers: [String]) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue[index]
        var updated = queue
        updated.remove(at: index)
        queue = updated

        let combined: String
        if request.questions.count > 1 {
            combined = zip(request.questions, answers)
                .map { "\($0.header): \($1)" }
                .joined(separator: "\n")
        } else {
            // Matches the pre-existing single-question wire format exactly
            // (no header prefix) — the common case must not regress.
            combined = answers.first ?? ""
        }
        request.connection?.respond(json: ["answer": combined])
    }

    func cancel(connection: SocketConnection) {
        queue = queue.filter { $0.connection !== connection }
    }
}
