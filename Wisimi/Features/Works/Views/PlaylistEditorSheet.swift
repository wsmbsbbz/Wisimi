import SwiftUI

enum PlaylistEditor: Identifiable {
    case create
    case edit(PlaylistSummary)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let playlist): "edit-\(playlist.id)"
        }
    }

    var title: String {
        switch self {
        case .create: "新建播放列表"
        case .edit: "编辑播放列表"
        }
    }

    var submitTitle: String {
        switch self {
        case .create: "创建"
        case .edit: "保存"
        }
    }
}

private enum PlaylistPrivacy: Int, CaseIterable, Identifiable {
    case `private` = 0
    case unlisted = 1
    case `public` = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .private: "私享"
        case .unlisted: "不公开"
        case .public: "公开"
        }
    }
}

struct PlaylistEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: PlaylistEditor
    let catalog: PlaylistCatalog
    let token: String?
    let onSaved: (PlaylistSummary) -> Void
    @State private var name: String
    @State private var description: String
    @State private var privacy: PlaylistPrivacy
    @State private var isSaving = false
    @State private var message: String?

    init(editor: PlaylistEditor, catalog: PlaylistCatalog, token: String?, onSaved: @escaping (PlaylistSummary) -> Void) {
        self.editor = editor
        self.catalog = catalog
        self.token = token
        self.onSaved = onSaved

        switch editor {
        case .create:
            _name = State(initialValue: "")
            _description = State(initialValue: "")
            _privacy = State(initialValue: .private)
        case .edit(let playlist):
            _name = State(initialValue: playlist.displayName)
            _description = State(initialValue: playlist.description)
            _privacy = State(initialValue: PlaylistPrivacy(rawValue: playlist.privacy) ?? .private)
        }
    }

    var body: some View {
        FormSheet(
            title: editor.title,
            submit: SheetSubmit(
                title: editor.submitTitle,
                isLoading: isSaving,
                isDisabled: trimmedName.isEmpty || token == nil
            ) {
                Task { await save() }
            },
            errorMessage: message
        ) {
            Section {
                TextField("名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("描述", text: $description, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("隐私") {
                Picker("隐私", selection: $privacy) {
                    ForEach(PlaylistPrivacy.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        guard let token else {
            message = "请先登录"
            return
        }

        isSaving = true
        message = nil
        do {
            let id: String?
            switch editor {
            case .create: id = nil
            case .edit(let playlist): id = playlist.id
            }
            let playlist = try await catalog.save(id: id, name: trimmedName, privacy: privacy.rawValue,
                                                   description: description, token: token)
            onSaved(playlist)
            dismiss()
        } catch {
            message = error.userFacingMessage
        }
        isSaving = false
    }
}
