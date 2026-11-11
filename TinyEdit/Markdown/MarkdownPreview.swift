import SwiftUI

struct MarkdownPreview: View {
    @Environment(AppState.self) private var appState

    @State private var imageAccess = MarkdownImageAccess()
    private var documentURL: URL? { appState.session.selectedBufferID.flatMap { appState.fileURLs[$0] } }

    var body: some View {
        MarkdownPage(blocks: appState.previewBlocks, message: appState.previewMessage,
                     identity: appState.session.selectedBufferID)
            .environment(\.markdownDocumentURL, documentURL)
            .environment(\.markdownImageAccess, imageAccess)
            .environment(\.markdownBodySize, MarkdownStyle.bodySize(editorFontSize: appState.settings.fontSize))
            .onChange(of: appState.session.selectedBufferID, initial: true) { _, _ in
                imageAccess.activate(document: documentURL)
            }
            .onChange(of: documentURL) { _, _ in imageAccess.activate(document: documentURL) }
            .onDisappear { imageAccess.reset() }
    }
}
