import Foundation

/// One scenario the LLM derived from a Library video. Mirrors the desktop
/// client's `RoleplayScenario` (Get_Video/client/src/tutor/types.ts) so the
/// two products converge on the same conceptual shape — but the wire format
/// is decoupled: we re-parse the LLM JSON ourselves rather than syncing
/// scenarios across platforms.
///
/// Identity is generated client-side (UUID) rather than trusting the LLM
/// to emit a stable id — observation: DeepSeek/Claude both invent random
/// ids on each call, so trying to "keep the same scenario across reloads"
/// via the LLM id is a fool's errand. Identity is local + per-load.
struct RoleplayScenario: Identifiable, Equatable, Codable {
    /// Local UUID. The LLM-supplied id (if any) is ignored.
    let id: UUID
    /// Short Chinese title shown on the card (e.g. "你当旅客我当海关").
    let title: String
    /// One-sentence English setup describing the scene. Fed into turnSystemPrompt.
    let setup: String
    /// What role the LEARNER plays (e.g. "旅客" / "tourist").
    let userRole: String
    /// What role the AGENT plays (e.g. "海关" / "customs officer").
    let agentRole: String
    /// 1 = A2-easy, 2 = B1-mid, 3 = B2-stretch. Drives the ★ row on the card.
    let difficulty: Int
    /// 3-5 English phrases the LLM expects to surface in this scene. These
    /// are the keys passed into ProductionProgressStore on per-turn verdicts,
    /// so they MUST be normalized the same way QuickChat normalizes corpus
    /// phrases (lower-cased, trimmed) — `normalizedHints` does the conversion.
    let vocabHints: [String]

    var normalizedHints: [String] {
        vocabHints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

/// Wire shape the scene-derivation LLM call returns.
///
///   { "scenarios": [
///       { "title": "...", "setup": "...", "userRole": "...",
///         "agentRole": "...", "difficulty": 1, "vocabHints": ["..."] }
///   ] }
///
/// We decode liberally — the LLM occasionally drops fields or stringifies
/// difficulty. Missing → safe fallback rather than throwing.
struct ScenarioDerivationResponse: Decodable {
    let scenarios: [RawScenario]

    struct RawScenario: Decodable {
        let title: String?
        let setup: String?
        let userRole: String?
        let agentRole: String?
        let difficulty: Int?
        let difficultyString: String?
        let vocabHints: [String]?

        enum CodingKeys: String, CodingKey {
            case title, setup, userRole, agentRole, difficulty, vocabHints
            // Desktop sometimes uses snake_case; tolerate both.
            case user_role, agent_role, vocab_hints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try? c.decode(String.self, forKey: .title)
            self.setup = try? c.decode(String.self, forKey: .setup)
            self.userRole = (try? c.decode(String.self, forKey: .userRole))
                ?? (try? c.decode(String.self, forKey: .user_role))
            self.agentRole = (try? c.decode(String.self, forKey: .agentRole))
                ?? (try? c.decode(String.self, forKey: .agent_role))
            // Tolerate "2" (string) as well as 2 (int) — DeepSeek does this
            // intermittently with JSON-mode disabled.
            if let i = try? c.decode(Int.self, forKey: .difficulty) {
                self.difficulty = i; self.difficultyString = nil
            } else if let s = try? c.decode(String.self, forKey: .difficulty) {
                self.difficulty = Int(s); self.difficultyString = s
            } else {
                self.difficulty = nil; self.difficultyString = nil
            }
            self.vocabHints = (try? c.decode([String].self, forKey: .vocabHints))
                ?? (try? c.decode([String].self, forKey: .vocab_hints))
        }
    }

    /// Convert raw entries into validated `RoleplayScenario`s. Drops any
    /// entry that's too malformed to render (missing title or setup).
    func toScenarios() -> [RoleplayScenario] {
        scenarios.compactMap { r in
            guard let title = r.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let setup = r.setup?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !setup.isEmpty else {
                return nil
            }
            let difficulty = max(1, min(3, r.difficulty ?? 2))
            let hints = (r.vocabHints ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return RoleplayScenario(
                id: UUID(),
                title: title,
                setup: setup,
                userRole: r.userRole?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tourist",
                agentRole: r.agentRole?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "local guide",
                difficulty: difficulty,
                vocabHints: hints
            )
        }
    }
}

/// State machine for the 角色扮演 tab. Picker is the resting state until
/// the user picks; running session is a sheet on top of the tab.
enum RoleplayPhase: Equatable {
    case idle           // pre-load (just mounted, no LLM call yet)
    case loading        // scene-derivation call in flight
    case picker         // scenarios ready, waiting for user pick
    case inSession      // user picked, session sheet is up
    case error(String)
}
