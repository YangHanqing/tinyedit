import Foundation
import Observation

struct ToastModel: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

enum ConflictAction: Equatable {
    case reloadFromDisk   // also Use Disk Version
    case keepMyVersion    // also Keep Recovered Version
    case saveAs
    case relocate         // in-session rebind only
}

/// The tab context menu's batch closes, relative to the tab that was right-clicked.
enum TabCloseScope {
    case others
    case left
    case right
    case all
}

struct BannerAction: Equatable, Identifiable {
    var title: String
    var action: ConflictAction
    var id: String { title }
}

struct BannerModel: Equatable {
    var text: String
    var actions: [BannerAction]
}

enum FlushResult { case success, failed }

/// The top-right card for text read from a picture.
enum ImageTextState: Equatable, Sendable {
    case recognizing
    case recognizingSlow
    /// Read after the tab changed or was switched away from, so not inserted on its own: Insert or Copy.
    case offer(String)
}

/// The top-right card for a curl request sent from the tab. The response body itself stays off observed state
/// (`AppState.curlBodies`); only a clipped preview is here.
enum CurlRunState: Equatable, Sendable {
    case sending(CurlSummary, started: Date)
    case finished(CurlSummary, CurlResult)
    case failed(CurlSummary, message: String)

    var summary: CurlSummary {
        switch self {
        case .sending(let s, _), .finished(let s, _), .failed(let s, _): s
        }
    }

    var isSending: Bool {
        if case .sending = self { true } else { false }
    }
}

struct CurlResult: Equatable, Sendable {
    var status: Int
    var reason: String
    var elapsed: Duration
    var byteCount: Int
    var headers: [CurlCommand.Header]
    var body: CurlResultBody
}

enum CurlResultBody: Equatable, Sendable {
    case empty
    case binary(mimeType: String?)
    /// The first part of the text; the whole of it is in `AppState.curlBodies`.
    case text(preview: String, language: EditorLanguage?)
}

@Observable
final class FindModel {
    var visible = false
    var showReplace = false
    var query = ""
    var replacement = ""
    var caseSensitive = false
    /// Matches in the active buffer; nil while the query is empty or not yet searched.
    var matchCount: Int?
    /// 1-based position of the match the selection is on.
    var currentMatch: Int?
    /// Counting stopped at `FindMatches.limit`.
    var capped = false
    var focusToken = 0
    var focusReplace = false
}
