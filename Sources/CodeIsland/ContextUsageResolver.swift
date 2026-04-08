import Foundation
import CodeIslandCore

enum ContextUsageResolver {
    static func readContextUsageFromTranscript(
        path: String,
        turnId: String?,
        source: String,
        stopEventRaw: [String: Any]
    ) -> ContextUsageSnapshot? {
        let expandedPath: String
        if path.hasPrefix("~/") {
            expandedPath = NSHomeDirectory() + "/" + path.dropFirst(2)
        } else {
            expandedPath = path
        }

        guard let text = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }

        var eventPayloads: [[String: Any]] = []
        var rawEvents: [[String: Any]] = []
        eventPayloads.reserveCapacity(lines.count)
        rawEvents.reserveCapacity(lines.count)
        for rawLine in lines {
            guard let data = rawLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            rawEvents.append(json)
            if let type = json["type"] as? String,
               type == "event_msg",
               let payload = json["payload"] as? [String: Any] {
                eventPayloads.append(payload)
            }
        }
        guard !rawEvents.isEmpty else { return nil }

        let normalizedSource = source.lowercased()
        if normalizedSource == "codex",
           let hit = parseCodexTranscriptContextUsage(rawEvents: rawEvents, eventPayloads: eventPayloads, turnId: turnId) {
            return hit
        }
        if normalizedSource == "claude",
           let hit = parseClaudeTranscriptContextUsage(rawEvents: rawEvents) {
            return hit
        }
        if let hit = parseGenericTranscriptContextUsage(rawEvents: rawEvents, stopEventRaw: stopEventRaw) {
            return hit
        }

        if let hit = parseCodexTranscriptContextUsage(rawEvents: rawEvents, eventPayloads: eventPayloads, turnId: turnId) {
            return hit
        }
        if let hit = parseClaudeTranscriptContextUsage(rawEvents: rawEvents) {
            return hit
        }
        return nil
    }

    private static func parseCodexTranscriptContextUsage(
        rawEvents: [[String: Any]],
        eventPayloads: [[String: Any]],
        turnId: String?
    ) -> ContextUsageSnapshot? {
        guard !rawEvents.isEmpty, !eventPayloads.isEmpty else { return nil }

        var startIndex = 0
        var endIndex = eventPayloads.count
        if let turnId {
            if let idx = eventPayloads.lastIndex(where: {
                ($0["type"] as? String) == "task_started" && ($0["turn_id"] as? String) == turnId
            }) {
                startIndex = idx
                if let nextIdx = eventPayloads[(idx + 1)...].firstIndex(where: { ($0["type"] as? String) == "task_started" }) {
                    endIndex = nextIdx
                }
            }
        }
        guard startIndex < endIndex else { return nil }
        let scopedPayloads = Array(eventPayloads[startIndex..<endIndex])

        var contextWindow: Int?
        for payload in scopedPayloads.reversed() {
            if let type = payload["type"] as? String,
               type == "task_started",
               let window = parseInt(payload["model_context_window"]),
               window > 0 {
                contextWindow = window
                break
            }
            if let type = payload["type"] as? String,
               type == "token_count",
               let info = payload["info"] as? [String: Any],
               let window = parseInt(info["model_context_window"]),
               window > 0 {
                contextWindow = window
                break
            }
        }
        guard let contextWindow, contextWindow > 0 else { return nil }

        var usedTokens: Int?
        for payload in scopedPayloads.reversed() {
            guard let type = payload["type"] as? String, type == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }

            var candidates: [Int] = []
            if let lastUsage = info["last_token_usage"] as? [String: Any] {
                if let input = parseInt(lastUsage["input_tokens"]) { candidates.append(input) }
                if let total = parseInt(lastUsage["total_tokens"]) { candidates.append(total) }
            }
            if let totalUsage = info["total_token_usage"] as? [String: Any] {
                if let input = parseInt(totalUsage["input_tokens"]) { candidates.append(input) }
                if let total = parseInt(totalUsage["total_tokens"]) { candidates.append(total) }
            }

            if let sane = candidates.first(where: { $0 > 0 && $0 <= Int(Double(contextWindow) * 1.2) }) {
                usedTokens = sane
                break
            }
            if let fallback = candidates.first(where: { $0 > 0 }) {
                usedTokens = min(fallback, contextWindow)
                break
            }
        }

        guard let usedTokens else { return nil }
        let ratio = min(max(Double(usedTokens) / Double(contextWindow), 0), 1)
        return ContextUsageSnapshot(usedTokens: usedTokens, totalTokens: contextWindow, ratio: ratio)
    }

    private static func parseClaudeTranscriptContextUsage(rawEvents: [[String: Any]]) -> ContextUsageSnapshot? {
        var inferredTotalTokens: Int?
        for event in rawEvents.reversed() {
            guard event["type"] as? String == "user",
                  let message = event["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  content.contains("Context Usage") || content.contains("tokens (")
            else { continue }

            if let parsed = parseContextUsageFromLocalCommandOutput(content) {
                inferredTotalTokens = parsed.total
                break
            }
        }

        var latestUsage: (input: Int, cacheRead: Int)?
        for event in rawEvents.reversed() {
            guard event["type"] as? String == "assistant",
                  let message = event["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let input = parseInt(usage["input_tokens"]) ?? 0
            let cacheRead = parseInt(usage["cache_read_input_tokens"]) ?? 0
            if input > 0 || cacheRead > 0 {
                latestUsage = (input, cacheRead)
                break
            }
        }

        guard let latestUsage else { return nil }
        let usedTokens = latestUsage.input + latestUsage.cacheRead
        guard usedTokens > 0 else { return nil }
        let total = inferredTotalTokens ?? 200_000
        guard total > 0 else { return nil }
        let ratio = min(max(Double(usedTokens) / Double(total), 0), 1)
        return ContextUsageSnapshot(usedTokens: usedTokens, totalTokens: total, ratio: ratio)
    }

    private static func parseGenericTranscriptContextUsage(
        rawEvents: [[String: Any]],
        stopEventRaw: [String: Any]
    ) -> ContextUsageSnapshot? {
        if let direct = extractContextUsage(from: stopEventRaw) {
            return direct
        }
        for event in rawEvents.reversed() {
            if let direct = extractContextUsage(from: event) {
                return direct
            }
            if let message = event["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let input = parseInt(usage["input_tokens"]) {
                let total = parseInt(usage["model_context_window"]) ?? 200_000
                if total > 0 {
                    let ratio = min(max(Double(input) / Double(total), 0), 1)
                    return ContextUsageSnapshot(usedTokens: input, totalTokens: total, ratio: ratio)
                }
            }
        }
        return nil
    }

    private static func parseInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let num = value as? NSNumber { return num.intValue }
        if let str = value as? String { return Int(str) }
        return nil
    }

    private static func parseContextUsageFromLocalCommandOutput(_ text: String) -> (used: Int, total: Int, percent: Int)? {
        let clean = stripANSI(text)
        let pattern = #"([0-9]+(?:\.[0-9]+)?)([kKmM]?)\s*/\s*([0-9]+(?:\.[0-9]+)?)([kKmM]?)\s*tokens\s*\(([0-9]+)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = clean as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: clean, range: range), m.numberOfRanges == 6 else { return nil }
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        guard let used = parseHumanNumber(g(1), unit: g(2)),
              let total = parseHumanNumber(g(3), unit: g(4)),
              let percent = Int(g(5)) else { return nil }
        return (used, total, percent)
    }

    private static func parseHumanNumber(_ numText: String, unit: String) -> Int? {
        guard let value = Double(numText) else { return nil }
        switch unit.lowercased() {
        case "k": return Int(value * 1_000)
        case "m": return Int(value * 1_000_000)
        default: return Int(value)
        }
    }

    private static func stripANSI(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u{001B}\[[0-9;]*[A-Za-z]"#) else { return s }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
