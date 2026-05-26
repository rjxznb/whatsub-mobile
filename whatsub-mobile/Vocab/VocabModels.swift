import Foundation

/// One saved phrase in a per-video vocab notebook. Local-only (Documents JSON).
struct VocabItem: Codable, Identifiable, Equatable {
    let id: String
    var phrase: String          // the saved phrase (a selection, or the whole sentence)
    var sentenceEn: String      // full cue English — kept as context
    var translationZh: String   // full cue Chinese — kept as context
    var note: String            // the user's own note (may be empty)
    var cueIndex: Int?          // jump-back target; nil once migrated across videos
    var sourceTitle: String?    // originating video title (shown in the staging area)
    let savedAt: Double         // epoch seconds

    init(
        id: String = UUID().uuidString,
        phrase: String,
        sentenceEn: String,
        translationZh: String,
        note: String = "",
        cueIndex: Int?,
        sourceTitle: String?,
        savedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.phrase = phrase
        self.sentenceEn = sentenceEn
        self.translationZh = translationZh
        self.note = note
        self.cueIndex = cueIndex
        self.sourceTitle = sourceTitle
        self.savedAt = savedAt
    }
}
