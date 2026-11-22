import Foundation

/// Plain words for the plugin's action ids. The plugin still owns the labels;
/// these give the app a consistent, short description around them.
enum FaceCopy {
    enum MomentGroup: String, CaseIterable, Identifiable {
        case needsAttention = "Needs attention"
        case working = "Working"
        case quiet = "Quiet"
        case more = "More"

        var id: String { rawValue }
    }

    static func group(for action: String) -> MomentGroup {
        switch action {
        case "approval", "question":
            return .needsAttention
        case "thinking", "tool_read", "tool_search", "tool_write",
             "tool_edit", "tool_exec", "waiting":
            return .working
        case "idle", "session_start", "done", "error", "hub_down", "sleep":
            return .quiet
        default:
            return .more
        }
    }

    static func headline(_ action: String) -> String {
        switch action {
        case "idle": return "Nothing is happening"
        case "session_start": return "Session started"
        case "thinking": return "DeepSeek is thinking"
        case "tool_read": return "DeepSeek is reading"
        case "tool_search": return "DeepSeek is searching"
        case "tool_write": return "DeepSeek is writing"
        case "tool_edit": return "DeepSeek is editing"
        case "tool_exec": return "DeepSeek is running a command"
        case "waiting": return "DeepSeek is waiting"
        case "approval": return "DeepSeek needs approval"
        case "question": return "DeepSeek has a question"
        case "done": return "Task finished"
        case "error": return "Something went wrong"
        case "hub_down": return "DeepSeek is not responding"
        case "sleep": return "Resting"
        default: return "DeepSeek is busy"
        }
    }

    static func short(_ action: String) -> String {
        switch action {
        case "idle": return "Idle"
        case "session_start": return "Started"
        case "thinking": return "Thinking"
        case "tool_read": return "Reading"
        case "tool_search": return "Searching"
        case "tool_write": return "Writing"
        case "tool_edit": return "Editing"
        case "tool_exec": return "Command"
        case "waiting": return "Waiting"
        case "approval": return "Approval"
        case "question": return "Question"
        case "done": return "Done"
        case "error": return "Error"
        case "hub_down": return "No link"
        case "sleep": return "Sleep"
        default: return "Busy"
        }
    }

    static func detail(_ action: String) -> String {
        switch action {
        case "idle": return "No action from DeepSeek."
        case "session_start": return "A new session is open."
        case "thinking": return "Working on the next step."
        case "tool_read": return "Opening a file or page."
        case "tool_search": return "Looking something up."
        case "tool_write": return "Writing or changing files."
        case "tool_edit": return "Making a targeted edit."
        case "tool_exec": return "Running a shell command."
        case "waiting": return "Waiting for a tool or reply."
        case "approval": return "Waiting for your go-ahead."
        case "question": return "Waiting for your answer."
        case "done": return "Ready for the next one."
        case "error": return "The last action failed."
        case "hub_down": return "The connection is down."
        case "sleep": return "No activity for a while."
        default: return "DeepSeek is busy."
        }
    }

    // MARK: - Device reactions

    static func reactionHeadline(_ animation: String) -> String {
        switch animation {
        case "dizzy": return "Shake"
        case "stroked": return "Stroke"
        default: return "Device reaction"
        }
    }

    static func reactionDetail(_ animation: String) -> String {
        switch animation {
        case "dizzy": return "Plays when cue9 is shaken."
        case "stroked": return "Plays when cue9 is stroked."
        default: return "Plays from cue9's sensors."
        }
    }

    static func reactionTrigger(_ animation: String) -> String {
        switch animation {
        case "dizzy": return "Shake"
        case "stroked": return "Stroke"
        default: return "On device"
        }
    }

    static func reactionSymbol(_ animation: String) -> String {
        switch animation {
        case "dizzy": return "gyroscope"
        case "stroked": return "hand.point.up.left"
        default: return "sensor"
        }
    }
}
