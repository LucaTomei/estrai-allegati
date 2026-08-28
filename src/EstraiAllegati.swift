// Estrai Allegati Office — app nativa macOS (SwiftUI).
// App completamente nativa e autonoma: estrazione in Extractor.swift, nessuna dipendenza esterna.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct Attachment: Identifiable {
    var id: String { path }
    let name: String
    let path: String      // copia temporanea (per Apri / drag & drop)
    let size: Int
    let kind: String
}

struct DocResult: Identifiable {
    let id = UUID()
    let docName: String
    let workDir: URL
    var attachments: [Attachment]
    var warnings: [String]
    var error: String?
}

final class Model: ObservableObject {
    @Published var results: [DocResult] = []
    @Published var busy = 0

    static let supported = Extractor.supportedExtensions

    func handle(urls: [URL]) {
        for url in urls {
            if Model.supported.contains(url.pathExtension.lowercased()) {
                extract(url)
            } else {
                results.insert(DocResult(docName: url.lastPathComponent, workDir: FileManager.default.temporaryDirectory,
                                         attachments: [], warnings: [], error: "Formato non supportato (.\(url.pathExtension))"), at: 0)
            }
        }
    }

    private func extract(_ url: URL) {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("EstraiAllegati", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        busy += 1
        DispatchQueue.global(qos: .userInitiated).async {
            var result = DocResult(docName: url.lastPathComponent, workDir: work, attachments: [], warnings: [], error: nil)
            do {
                let data = try Data(contentsOf: url)
                let r = try Extractor.extract(data, filename: url.lastPathComponent)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                for f in r.files {
                    let dest = work.appendingPathComponent(f.name)
                    try f.data.write(to: dest)
                    result.attachments.append(Attachment(name: f.name, path: dest.path, size: f.data.count, kind: f.kind))
                }
                result.warnings = r.warnings
            } catch {
                result.error = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy -= 1
                self.results.insert(result, at: 0)
            }
        }
    }

    // MARK: salvataggio
    func save(_ a: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.name
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let dest = panel.url {
            copy(from: URL(fileURLWithPath: a.path), to: dest)
        }
    }

    func saveAll(_ r: DocResult) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Salva qui"
        panel.message = "Scegli la cartella in cui salvare \(r.attachments.count) allegati"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let dir = panel.url {
            for a in r.attachments { copy(from: URL(fileURLWithPath: a.path), to: dir.appendingPathComponent(a.name)) }
            NSWorkspace.shared.activateFileViewerSelecting(r.attachments.map { dir.appendingPathComponent($0.name) })
        }
    }

    private func copy(from: URL, to: URL) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        } catch {
            let al = NSAlert(); al.messageText = "Impossibile salvare"; al.informativeText = error.localizedDescription; al.runModal()
        }
    }

    func openDocumentDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = Model.supported.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { handle(urls: panel.urls) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var over = false

    var body: some View {
        VStack(spacing: 14) {
            dropZone
            if model.results.isEmpty {
                Spacer()
                Text("Nessun documento ancora aperto.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.results) { r in ResultCard(r: r) }
                    }.padding(.horizontal, 2)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 440)
    }

    var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "paperclip.circle.fill").font(.system(size: 34)).foregroundStyle(.tint)
            Text("Trascina qui un documento Word / Excel / PowerPoint").font(.headline)
            Text("oppure").foregroundStyle(.secondary).font(.caption)
            Button("Scegli file…") { model.openDocumentDialog() }
            if model.busy > 0 { ProgressView().controlSize(.small).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity).padding(22)
        .background(RoundedRectangle(cornerRadius: 14).fill(over ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(over ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [7])))
        .onDrop(of: [UTType.fileURL], isTargeted: $over) { providers in
            let group = DispatchGroup(); var urls: [URL] = []
            for p in providers {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) }
                    else if let u = item as? URL { urls.append(u) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.handle(urls: urls) }
            return true
        }
    }
}

struct ResultCard: View {
    @EnvironmentObject var model: Model
    let r: DocResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.fill").foregroundStyle(.secondary)
                Text(r.docName).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if r.attachments.count > 1 {
                    Button("Salva tutti…") { model.saveAll(r) }
                }
            }
            if let e = r.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            } else if r.attachments.isEmpty {
                Text("Nessun allegato incorporato trovato.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(r.attachments) { a in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.body).textSelection(.enabled)
                            Text("\(a.kind) · \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apri") { NSWorkspace.shared.open(URL(fileURLWithPath: a.path)) }.buttonStyle(.link)
                        Button("Salva…") { model.save(a) }
                    }
                    .padding(.vertical, 3)
                    .onDrag { NSItemProvider(object: URL(fileURLWithPath: a.path) as NSURL) }
                }
            }
            ForEach(r.warnings, id: \.self) { w in
                Label(w, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: Model?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) { model?.handle(urls: urls) }
    func applicationWillTerminate(_ notification: Notification) {
        // pulizia file temporanei
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("EstraiAllegati")
        try? FileManager.default.removeItem(at: tmp)
    }
}

@main
struct EstraiAllegatiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("Estrai Allegati") {
            ContentView().environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Apri documento…") { model.openDocumentDialog() }.keyboardShortcut("o")
            }
        }
    }
}
