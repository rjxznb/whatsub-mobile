import Foundation

struct ManagedAnalysisSSEMessage: Equatable {
    let id: Int64?
    let event: String?
    let data: String
    let retryMilliseconds: Int?
}

enum ManagedAnalysisSSEParseError: Error, Equatable {
    case invalidUTF8
    case malformedJSON(event: String, eventID: Int64?)
}

/// Incrementally parses Server-Sent Events without depending on URLSession.
/// Bytes stay buffered until a full line is available, so a multi-byte UTF-8
/// scalar may be split at any transport boundary without corrupting the text.
struct ManagedAnalysisSSEParser {
    private var byteBuffer = Data()
    private var eventName: String?
    private var eventID: Int64?
    private var retryMilliseconds: Int?
    private var dataLines: [String] = []
    private var isFinished = false

    mutating func push(_ bytes: Data) throws -> [ManagedAnalysisSSEMessage] {
        guard !isFinished else { return [] }
        byteBuffer.append(bytes)

        var messages: [ManagedAnalysisSSEMessage] = []
        while let newline = byteBuffer.firstIndex(of: 0x0A) {
            let lineBytes = Data(byteBuffer[..<newline])
            byteBuffer.removeSubrange(...newline)
            if let message = try consumeLine(lineBytes) {
                messages.append(message)
            }
        }
        return messages
    }

    mutating func finish() throws -> [ManagedAnalysisSSEMessage] {
        guard !isFinished else { return [] }
        isFinished = true

        var messages: [ManagedAnalysisSSEMessage] = []
        if !byteBuffer.isEmpty {
            let finalLine = byteBuffer
            byteBuffer.removeAll(keepingCapacity: false)
            if let message = try consumeLine(finalLine) {
                messages.append(message)
            }
        }
        if let message = dispatchEvent() {
            messages.append(message)
        }
        return messages
    }

    private mutating func consumeLine(_ rawLine: Data) throws -> ManagedAnalysisSSEMessage? {
        var lineBytes = rawLine
        if lineBytes.last == 0x0D {
            lineBytes.removeLast()
        }
        guard let line = String(data: lineBytes, encoding: .utf8) else {
            throw ManagedAnalysisSSEParseError.invalidUTF8
        }
        guard !line.isEmpty else {
            return dispatchEvent()
        }
        guard !line.hasPrefix(":") else {
            return nil
        }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            eventName = String(value)
        case "data":
            dataLines.append(String(value))
        case "id":
            if !value.contains("\0"), let parsed = Int64(value) {
                eventID = parsed
            }
        case "retry":
            if let parsed = Int(value), parsed >= 0 {
                retryMilliseconds = parsed
            }
        default:
            break
        }
        return nil
    }

    private mutating func dispatchEvent() -> ManagedAnalysisSSEMessage? {
        defer { resetEventFields() }
        guard !dataLines.isEmpty else { return nil }
        return ManagedAnalysisSSEMessage(
            id: eventID,
            event: eventName,
            data: dataLines.joined(separator: "\n"),
            retryMilliseconds: retryMilliseconds
        )
    }

    private mutating func resetEventFields() {
        eventName = nil
        eventID = nil
        retryMilliseconds = nil
        dataLines.removeAll(keepingCapacity: true)
    }
}
