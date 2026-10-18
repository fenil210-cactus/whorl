import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhorlCore

extension Color {
    static let whorl = Color(nsColor: AppInfo.accent)
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 400, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in layout.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

struct HomeView: View {
    @ObservedObject var model: ConvertModel
    var openSettings: () -> Void = {}
    var chooseFiles: () -> Void = {}
    @State private var targeted = false
    @State private var trusted = Permissions.accessibilityGranted
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.files.isEmpty {
                        DropZone(targeted: targeted, choose: chooseFiles)
                        WheelCard(trusted: trusted)
                        Capabilities(engines: model.engines)
                    } else {
                        FileList(model: model)
                        if let request = model.running {
                            ProgressCard(model: model, request: request)
                        } else if let result = model.result {
                            ResultCard(model: model, result: result)
                        } else {
                            Chooser(model: model)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 580, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if targeted && !model.files.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.whorl, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.whorl.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Self.load(providers) { model.add($0) }
            return true
        }
        .onReceive(tick) { _ in trusted = Permissions.accessibilityGranted }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: StatusIcon.make(size: 30, template: false))
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Whorl").font(.system(size: 17, weight: .bold))
                Text("Free, offline file converter").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !model.files.isEmpty {
                Button { model.clear() } label: { Label("Start over", systemImage: "xmark.circle") }
                    .buttonStyle(.borderless).disabled(model.running != nil)
            }
            Button(action: chooseFiles) { Label("Add files", systemImage: "plus") }.disabled(model.running != nil)
            Button(action: openSettings) { Image(systemName: "gearshape") }.help("Settings")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let sorted = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            MainActor.assumeIsolated { done(sorted) }
        }
    }
}

// MARK: - Empty state

struct DropZone: View {
    var targeted: Bool
    var choose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.whorl)
            Text("Drop files here").font(.system(size: 20, weight: .semibold))
            Text("Photos, videos, audio, PDFs, documents, spreadsheets, subtitles, archives. Folders too.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Files…", action: choose).controlSize(.large).buttonStyle(.borderedProminent).tint(.whorl)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(targeted ? Color.whorl.opacity(0.12) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? Color.whorl : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [7, 6]))
        )
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

struct WheelCard: View {
    var trusted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: trusted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 24)).foregroundStyle(trusted ? Color.green : Color.whorl)
            VStack(alignment: .leading, spacing: 6) {
                Text(trusted ? "The wheel is on" : "Optional: use the wheel from anywhere").font(.system(size: 14, weight: .semibold))
                if trusted {
                    Text("Start dragging a file in Finder, then tap \(keys). Drop it on a wedge. The result lands next to the original.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else {
                    Text("Whorl can open a wheel while you drag a file in Finder. macOS needs your OK for Whorl to notice the key tap. The window above works without it.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    HStack {
                        Button("Turn on…") { Permissions.requestAccessibility() }.buttonStyle(.borderedProminent).tint(.whorl).controlSize(.small)
                        Button("Open Settings") { Permissions.openAccessibilitySettings() }.controlSize(.small)
                    }
                    Text("After you switch Whorl on there, this card updates by itself.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var keys: String {
        WheelMode.allCases.map { "\(Prefs.key(for: $0).symbol) \($0.title)" }.joined(separator: ", ")
    }
}

struct Capabilities: View {
    var engines: Engines

    private struct Family: Identifiable {
        let id: String
        let symbol: String
        let sample: String
        var note: String?
    }

    private let families: [Family] = [
        Family(id: "Images", symbol: "photo", sample: "png"),
        Family(id: "Video", symbol: "film", sample: "mp4", note: "mkv"),
        Family(id: "Audio", symbol: "waveform", sample: "wav"),
        Family(id: "PDF", symbol: "doc.richtext", sample: "pdf"),
        Family(id: "Documents", symbol: "doc.text", sample: "docx"),
        Family(id: "Spreadsheets", symbol: "tablecells", sample: "xlsx"),
        Family(id: "Subtitles", symbol: "captions.bubble", sample: "srt"),
        Family(id: "Archives", symbol: "archivebox", sample: "zip"),
        Family(id: "Slides", symbol: "rectangle.on.rectangle", sample: "pptx"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Whorl can do").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(families) { family in card(family) }
            }
        }
    }

    private func card(_ family: Family) -> some View {
        let have = Set(Catalog.outputs(forExtension: family.sample, engines: engines))
        let all = Catalog.outputs(forExtension: family.sample, engines: .everything)
        let missing = all.filter { !have.contains($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Label(family.id, systemImage: family.symbol).font(.system(size: 13, weight: .semibold))
            FlowLayout(spacing: 5) {
                ForEach(all, id: \.self) { format in
                    Text(format.label)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(have.contains(format) ? Color.whorl.opacity(0.16) : Color.primary.opacity(0.05)))
                        .foregroundStyle(have.contains(format) ? Color.whorl : Color.secondary.opacity(0.6))
                }
            }
            if all.isEmpty {
                Text("Needs LibreOffice").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !missing.isEmpty {
                Text(hint(for: family)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private func hint(for family: Family) -> String {
        switch family.id {
        case "Video", "Audio": return "Grey formats need ffmpeg (brew install ffmpeg)"
        case "Images": return "Grey formats need the webp tool (brew install webp)"
        default: return "Grey formats need more tools"
        }
    }
}

// MARK: - Files loaded

struct FileList: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.files.count) \(model.files.count == 1 ? "file" : "files")")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(model.files.prefix(40).enumerated()), id: \.element) { index, url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Text("\(url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()) · \(ConvertModel.size(url))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary).disabled(model.running != nil)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    if index < min(model.files.count, 40) - 1 { Divider().padding(.leading, 50).opacity(0.5) }
                }
                if model.files.count > 40 {
                    Text("+ \(model.files.count - 40) more").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        }
    }
}

struct Chooser: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.targets.isEmpty && !model.tools.isEmpty {
                Picker("", selection: $model.tab) {
                    Text("Convert to").tag(ConvertModel.Tab.convert)
                    Text("Tools").tag(ConvertModel.Tab.tools)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if model.tab == .convert || model.tools.isEmpty {
                convert
            } else {
                tools
            }
        }
    }

    @ViewBuilder private var convert: some View {
        if model.targets.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                Text(model.reason ?? "Nothing to convert to.").font(.system(size: 13)).textSelection(.enabled)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
        } else {
            Text("Convert to").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 10) {
                ForEach(model.targets, id: \.self) { format in
                    Button { model.run(.convert(format)) } label: {
                        Text(format.label).font(.system(size: 14, weight: .bold, design: .rounded)).frame(minWidth: 52).padding(.vertical, 8).padding(.horizontal, 6)
                    }
                    .buttonStyle(ChipStyle())
                }
            }
            Text("The new file is saved next to the original. Originals are never changed.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var tools: some View {
        Text("Tools").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
            ForEach(model.tools, id: \.self) { tool in
                Button { model.run(.tool(tool)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: Wedge.tool(tool).symbol ?? "wrench").frame(width: 22).foregroundStyle(Color.whorl)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.label.capitalized).font(.system(size: 13, weight: .semibold))
                            Text(tool.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ChipStyle(radius: 12))
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(configuration.isPressed ? Color.whorl.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
    }
}

struct ProgressCard: View {
    @ObservedObject var model: ConvertModel
    var request: JobRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.system(size: 14, weight: .semibold))
            ProgressView(value: model.fraction).tint(.whorl)
            HStack {
                Text(model.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { model.cancel() }.controlSize(.small)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

struct ResultCard: View {
    @ObservedObject var model: ConvertModel
    var result: JobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: headlineSymbol).font(.system(size: 22)).foregroundStyle(headlineColor)
                Text(headline).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !result.outputs.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }.buttonStyle(.borderedProminent).tint(.whorl)
                }
            }
            ForEach(result.outputs, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                    Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ConvertModel.size(url)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
            }
            ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.file).font(.system(size: 12, weight: .semibold))
                        Text(failure.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Button("Convert again") { model.result = nil }
                Button("Start over") { model.clear() }
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var headline: String {
        if result.cancelled { return "Cancelled" }
        if result.outputs.isEmpty && result.failures.isEmpty { return "Nothing to do. These files are already in that format." }
        if result.failures.isEmpty { return result.outputs.count == 1 ? "Done" : "Done · \(result.outputs.count) files" }
        return result.outputs.isEmpty ? "That did not work" : "Done, with \(result.failures.count) problem\(result.failures.count == 1 ? "" : "s")"
    }
    private var headlineSymbol: String { result.failures.isEmpty && !result.cancelled ? "checkmark.circle.fill" : "exclamationmark.circle.fill" }
    private var headlineColor: Color { result.failures.isEmpty && !result.cancelled ? .green : .orange }
}
