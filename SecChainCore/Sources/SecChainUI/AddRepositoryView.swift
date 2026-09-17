import SecChainCore
import SwiftUI

/// Sheet for making a repository appear in the list. On the Mac the usual way is to choose the
/// checkout folder, from which the identity is derived exactly as `secchain` does it; typing the
/// identifier is the only way on iOS and the fallback on the Mac.
struct AddRepositoryView: View {
    /// Called with the chosen repository.
    let add: (RepositoryIdentity) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var identifierText = ""
    @State private var folderErrorDescription: String?
    #if os(macOS)
    @State private var isChoosingFolder = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                Section {
                    Button("Choose Folder", systemImage: "folder") {
                        isChoosingFolder = true
                    }
                    if let folderErrorDescription {
                        Text(folderErrorDescription)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("The repository is identified by its Git remote, so every checkout of it shares the same secrets")
                }
                #endif
                Section {
                    // Only the entered identifier is monospaced; the Mac shows the label beside it.
                    TextField(text: $identifierText, prompt: Text("github.com/owner/repository")) {
                        Text("Identifier")
                            .font(.body)
                    }
                    .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } footer: {
                    Text("A Git remote URL is accepted too and is normalized the same way secchain does it")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Repository")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        finish(repositoryIdentity: repositoryIdentity(enteredText: identifierText))
                    }
                    .disabled(identifierText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #if os(macOS)
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let folder) = result else {
                    return
                }
                do {
                    let definitionText = try SecretDefinitionFile.readText(
                        workingTreeRoot: try RepositoryIdentityResolver.workingTreeRoot(directory: folder) ?? folder
                    )
                    finish(
                        repositoryIdentity: try RepositoryIdentityResolver.resolve(
                            directory: folder,
                            declaredIdentifier: try definitionText.map(SecretDefinitionText.parse(text:))?.declaredRepositoryIdentifier
                        )
                    )
                } catch {
                    folderErrorDescription = "\(error)"
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 280)
        #endif
    }

    func finish(repositoryIdentity: RepositoryIdentity) {
        add(repositoryIdentity)
        dismiss()
    }
}

/// A pasted remote URL, or a `host/owner/repository` typed by hand, becomes the same identifier
/// the command-line tool derives from the Git remote. Anything else is taken literally, exactly
/// like `@repository` in a definition file.
func repositoryIdentity(enteredText: String) -> RepositoryIdentity {
    let trimmedText = enteredText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedText.contains("://") || trimmedText.contains("@") {
        return RepositoryIdentity(value: RepositoryRemoteURL.normalizedIdentifier(remoteURL: trimmedText) ?? trimmedText)
    }
    // `github.com/owner/repo`: a first path component with a dot is a host name.
    if let host = trimmedText.split(separator: "/").first, host.contains("."), trimmedText.contains("/") {
        return RepositoryIdentity(value: RepositoryRemoteURL.normalizedIdentifier(remoteURL: "https://" + trimmedText) ?? trimmedText)
    }
    return RepositoryIdentity(value: trimmedText)
}
