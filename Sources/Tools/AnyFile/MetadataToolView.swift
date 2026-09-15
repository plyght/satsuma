import SwiftUI

@MainActor
struct MetadataToolView: View {
    let session: ToolSession
    @State private var fields: [MetadataField] = []
    @State private var loading = true
    @State private var search = ""
    @State private var removeAll = false
    @State private var removeSensitive = false
    @State private var selectedFile: URL

    init(session: ToolSession) {
        self.session = session
        _selectedFile = State(initialValue: session.primary)
    }

    private var groups: [(String, [MetadataField])] {
        let filtered = fields.filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
        let order = ["File", "Media", "Document", "Tags", "Image", "Exif", "TIFF", "GPS", "IPTC", "MakerApple", "Chapters"]
        var dict: [String: [MetadataField]] = [:]
        for field in filtered { dict[field.group, default: []].append(field) }
        return dict.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max
            let ib = order.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }.map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Save copy" : "Apply to \(session.files.count) files", onSave: run) {
            VStack(spacing: 0) {
                HStack {
                    if session.files.count > 1 {
                        Picker("File", selection: $selectedFile) {
                            ForEach(session.files, id: \.self) { Text($0.lastPathComponent).tag($0) }
                        }
                        .frame(maxWidth: 320)
                    }
                    Spacer()
                    TextField("Search fields", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                .padding(12)
                Divider()
                if loading {
                    LoadingOrError(error: nil)
                } else if fields.isEmpty {
                    Text("No metadata found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups, id: \.0) { group, items in
                            Section(group) {
                                ForEach(items) { field in
                                    row(field)
                                }
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .disabled(removeAll)
                    .opacity(removeAll ? 0.4 : 1)
                }
            }
        } sidebar: {
            SidebarSection(title: "Remove") {
                Toggle("Remove all metadata", isOn: $removeAll)
                Toggle("Remove camera, GPS and processing data", isOn: $removeSensitive).disabled(removeAll)
                Text("Pixel data, page content and audio are untouched. Orientation and color profile are kept.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Editing") {
                Text("Editable fields show a text box. Clear a value to remove that field. Changes apply to a new copy; the original stays as is.")
                    .font(.caption2).foregroundStyle(.secondary)
                if session.files.count > 1 {
                    Text("Edited field values are applied to every selected file; removal options apply to all.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Summary") {
                let sensitive = fields.filter(\.sensitive).count
                Text("\(fields.count) fields · \(sensitive) sensitive").font(.callout.monospacedDigit())
            }
        }
        .task(id: selectedFile) { await load() }
    }

    @ViewBuilder
    private func row(_ field: MetadataField) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 4) {
                if field.sensitive {
                    Icon(.alertTriangle, size: 12).foregroundStyle(.orange).font(.caption)
                }
                Text(field.key).font(.callout).frame(width: 200, alignment: .leading).lineLimit(1)
            }
            if field.editable, let index = fields.firstIndex(where: { $0.id == field.id }) {
                TextField("", text: $fields[index].value)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(field.value).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                Spacer()
            }
        }
    }

    private func load() async {
        loading = true
        let url = selectedFile
        let result = await MetadataOps.read(url)
        fields = result
        loading = false
    }

    private func run() {
        let edits = fields.filter(\.editable)
        let removeAll = removeAll
        let removeSensitive = removeSensitive
        for url in session.files {
            guard let format = FileFormat.detect(url) else { continue }
            let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
            let ext = format.category == .image && !ImageIOBridge.canEncodeNatively(format) ? "png" : url.pathExtension
            let destination = ConversionMatrix.uniqueURL(directory: session.outputDirectory, baseName: base, suffix: removeAll ? "clean" : "edited", ext: ext)
            JobRunner.shared.run(title: "Metadata \(url.lastPathComponent)") { progress in
                try await MetadataOps.write(url, edits: edits, removeAll: removeAll, removeSensitive: removeSensitive, to: destination, progress: progress)
                return [destination]
            }
        }
        ToolWindowManager.shared.close(session)
    }
}
