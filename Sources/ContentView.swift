import SwiftUI

struct ConvertedFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let url: URL?
    let message: String
    let ok: Bool
}

private func xtdName(_ name: String) -> String {
    if name.lowercased().hasSuffix(".wtd") { return String(name.dropLast(4)) + ".xtd" }
    return name
}

func convertOne(_ url: URL) -> ConvertedFile {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let base = url.deletingPathExtension().lastPathComponent
    let isZip = url.pathExtension.lowercased() == "zip"
    let outName = isZip ? base + "_xtd.zip" : base + ".xtd"
    do {
        let bytes = [UInt8](try Data(contentsOf: url))
        var outBytes: [UInt8]
        var lines = [String]()
        if isZip {
            var converted = [ZipEntry]()
            var skipped = 0
            for entry in try ZipArchive.read(bytes) {
                let leaf = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
                if entry.name.hasPrefix("__MACOSX/") || leaf.hasPrefix("._") || !leaf.lowercased().hasSuffix(".wtd") {
                    skipped += 1
                    continue
                }
                do {
                    let r = try WTDConverter.convert(entry.data)
                    converted.append(ZipEntry(name: xtdName(entry.name), data: r.bytes))
                    lines.append(contentsOf: r.notes.map { "\(entry.name): \($0)" })
                } catch {
                    lines.append("\(entry.name): FAILED – \(error.localizedDescription)")
                }
            }
            let failed = lines.filter { $0.contains("FAILED") }.count
            guard !converted.isEmpty else {
                throw ConvertError.message(lines.isEmpty ? "No .wtd files found in the zip." : lines.joined(separator: "\n"))
            }
            lines.insert("\(converted.count) converted, \(failed) failed, \(skipped) non-.wtd file(s) skipped.", at: 0)
            outBytes = try ZipArchive.write(converted)
        } else {
            let r = try WTDConverter.convert(bytes)
            outBytes = r.bytes
            lines = r.notes.isEmpty ? ["Converted"] : r.notes
        }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(outName)
        try Data(outBytes).write(to: outURL, options: .atomic)
        return ConvertedFile(name: outName, url: outURL, message: lines.joined(separator: "\n"), ok: true)
    } catch {
        return ConvertedFile(name: url.lastPathComponent, url: nil, message: error.localizedDescription, ok: false)
    }
}

struct ContentView: View {
    @State private var showImporter = false
    @State private var results: [ConvertedFile] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Choose .wtd or .zip files", systemImage: "doc.badge.plus")
                    }
                    .disabled(busy)
                    if busy { ProgressView("Converting…") }
                }
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { r in
                            HStack(alignment: .top) {
                                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(r.ok ? .green : .red)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.name).font(.headline)
                                    Text(r.message).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let url = r.url {
                                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                }
                            }
                        }
                    }
                }
                Section("About") {
                    Text("Converts PC GTA IV-style texture dictionaries (.wtd) to Xbox 360 (.xtd). Pick a .zip to convert every .wtd inside it; you get back a zip of .xtd files with the same folder layout. DXT1, DXT3 and DXT5 textures are supported; only the top mip level is kept. Tap the share icon to save the result to Files.")
                        .font(.footnote)
                }
            }
            .navigationTitle("WTD → XTD")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                handle(result)
            }
        }
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            results = [ConvertedFile(name: "Import", url: nil, message: error.localizedDescription, ok: false)]
        case .success(let urls):
            busy = true
            Task {
                var out: [ConvertedFile] = []
                for url in urls {
                    out.append(await Task.detached { convertOne(url) }.value)
                }
                results = out
                busy = false
            }
        }
    }
}
