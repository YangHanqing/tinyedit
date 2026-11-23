import Foundation

/// The displayed mask is only a placeholder, never a credential sent or saved.
struct TranslationCredentialDraft {
    private(set) var value = ""
    private(set) var isEdited = false
    var hasSavedKey = false
    var showsSavedMask: Bool { hasSavedKey && !isEdited }

    mutating func edit(_ value: String) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        isEdited = true
    }

    func keyForRequest(readSaved: () throws -> String) throws -> String {
        isEdited ? value : try readSaved()
    }

    func keyForRequest(readSaved: () async throws -> String) async throws -> String {
        isEdited ? value : try await readSaved()
    }

    func persist(write: (String) throws -> Void) throws {
        if isEdited { try write(value) }
    }

    func persist(write: (String) async throws -> Void) async throws {
        if isEdited { try await write(value) }
    }

    mutating func didSave() {
        if isEdited { hasSavedKey = !value.isEmpty }
        value = ""
        isEdited = false
    }
}
