import AppKit
import SwiftUI
import WhorlCore

/// Runs a conversion off the main thread and reports back on it.
final class JobHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

enum JobRunner {
    @discardableResult
    static func start(
        _ request: JobRequest,
        inputs: [URL],
        progress: @escaping @MainActor (JobProgress) -> Void,
        completion: @escaping @MainActor (JobResult) -> Void
    ) -> JobHandle {
        let handle = JobHandle()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Jobs.run(request, inputs: inputs, engines: .current, progress: { update in
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(update) } }
            }, isCancelled: { handle.cancelled })
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
        return handle
    }
}

// MARK: - The small progress window used by the wheel

@MainActor
final class HUDModel: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
    @Published var fraction = 0.0
    @Published var finished = false
    @Published var isNotice = false
    @Published var symbol = "checkmark.circle.fill"
    @Published var outputs: [URL] = []
    @Published var problem: String?
    var handle: JobHandle?
    var onClose: () -> Void = {}
}

@MainActor
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var model = HUDModel()
    private var dismiss: DispatchWorkItem?

    func run(_ request: JobRequest, inputs: [URL]) {
        close()
        let model = HUDModel()
        self.model = model
        model.title = request.title
        model.detail = inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files"
        model.onClose = { [weak self] in self?.close() }
        show(model)
        model.handle = JobRunner.start(request, inputs: inputs, progress: { update in
            model.fraction = update.fraction
            if !update.name.isEmpty { model.detail = update.total > 1 ? "\(update.name) · \(update.done + 1) of \(update.total)" : update.name }
        }, completion: { [weak self] result in
            model.fraction = 1
            model.finished = true
            model.outputs = result.outputs
            if let failure = result.failures.first {
                model.problem = result.failures.count > 1 ? "\(failure.file): \(failure.message) (+\(result.failures.count - 1) more)" : "\(failure.file): \(failure.message)"
            } else if result.cancelled {
                model.problem = "Cancelled"
            }
            if model.problem == nil { self?.scheduleDismiss() }
        })
    }

    /// Shows a one-line message without a job (for example a copied path).
    func notice(_ text: String, symbol: String = "checkmark.circle.fill") {
        close()
        let model = HUDModel()
        self.model = model
        model.title = text
        model.finished = true
        model.isNotice = true
        model.fraction = 1
        model.symbol = symbol
        model.onClose = { [weak self] in self?.close() }
        show(model)
        scheduleDismiss(after: 1.8)
    }

    func fail(_ text: String) {
        close()
        let model = HUDModel()
        self.model = model
        model.title = "Whorl"
        model.finished = true
        model.problem = text
        model.onClose = { [weak self] in self?.close() }
        show(model)
    }

    private func show(_ model: HUDModel) {
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 92)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 340 - 16, y: frame.maxY - 92 - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func scheduleDismiss(after seconds: Double = 6) {
        let item = DispatchWorkItem { [weak self] in self?.close() }
        dismiss = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func close() {
        dismiss?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let problem = model.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
                } else if model.finished, !model.isNotice {
                    Text(model.outputs.isEmpty ? "Nothing to do. Already in that format." : (model.outputs.count == 1 ? model.outputs[0].lastPathComponent : "\(model.outputs.count) files created"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else if !model.finished {
                    ProgressView(value: model.fraction).progressViewStyle(.linear).tint(Color(nsColor: AppInfo.accent))
                    Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.finished, !model.outputs.isEmpty {
                Button("Show") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
                    model.onClose()
                }
                .controlSize(.small)
            } else if !model.finished {
                Button("Cancel") { model.handle?.cancel() }.controlSize(.small)
            } else if model.problem != nil {
                Button("Close") { model.onClose() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 340, height: 92, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder private var icon: some View {
        if model.problem != nil {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
        } else if model.finished {
            Image(systemName: model.symbol).font(.system(size: 22)).foregroundStyle(.green)
        } else {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 22)).foregroundStyle(Color(nsColor: AppInfo.accent))
        }
    }
}
