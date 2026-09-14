// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import SwiftUI
import CoreData
import Combine
#if os(iOS)
import MessageUI
#endif

/// NOTE: This view is not translated on purpose.
/// We want to make sure users only send us reports in English
@MainActor
struct DiagnosticsView: View {
   
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
        predicate: ZimFile.integrityCheckablePredicate()
    ) private var zimFiles: FetchedResults<ZimFile>
    @ObservedObject var model = GlobalDiagnosticsModel.shared
    
    private enum Const {
        #if os(iOS)
        static let verticalSpace: CGFloat = 32
        #else
        static let verticalSpace: CGFloat = 12
        #endif
    }
    
    var body: some View {
        VStack(alignment: .center) {
            Spacer()
            diagnosticItems
            Spacer(minLength: Const.verticalSpace)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                switch model.state {
                case .initial:
#if os(macOS)
                    runButton(again: false)
#endif
                case .running:
                    VStack(alignment: .center) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        #if os(macOS)
                            .scaleEffect(0.5)
                            .padding(-8)
                        #endif
                        
                        Text("Checking...")
                            .foregroundStyle(.secondary)
                        
                        #if os(macOS)
                        cancelButton
                        #endif
                    }
                    .padding(.vertical)
                case let .complete(logs):
#if os(macOS)
                    emailButton(logs: logs)
                    saveButton(logs: logs)
                    runButton(again: true)
#else
                    NavigationLink {
                        DiagnosticReportPreview(logs: logs)
                    } label: {
                        Label("Review & Share", systemImage: "doc.text.magnifyingglass")
                    }
#endif
                }
            }
            Spacer(minLength: Const.verticalSpace)
        }
        .frame(maxWidth: 500)
        .navigationTitle("Diagnostic Report")
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch model.state {
                case .initial:
                    runButton(again: false)
                        .padding(.horizontal)
                case .complete:
                    runButton(again: true)
                        .padding(.horizontal)
                case .running:
                    cancelButton
                        .padding(.horizontal)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .padding(.horizontal, 40)
#else
        .tabItem { Label("Diagnostics", systemImage: "exclamationmark.bubble") }
#endif
    }
    
    @ViewBuilder
    var diagnosticItems: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.items, id: \.id) { item in
                    Label(item.title, systemImage: item.status.systemImage)
                        .listItemTint(item.status.tintColor)
                        .listRowSeparator(.hidden)
                        .symbolEffect(.bounce, value: item.status.isComplete)
                }
            }
            #if os(iOS)
            .listRowSpacing(-10)
            #endif
            .listStyle(.plain)
            .onChange(of: model.state) {
                adjustScroll(using: proxy)
            }
            .onChange(of: model.items) {
                scrollToFirstInitialItem(using: proxy)
            }
            .task {
                adjustScroll(using: proxy)
            }
        }
    }
    
    private func adjustScroll(using proxy: ScrollViewProxy) {
        switch model.state {
        case .initial, .running:
            scrollToFirstInitialItem(using: proxy)
        case .complete:
            scrollToLastItem(using: proxy)
        }
    }
    
    private func scrollToFirstInitialItem(using proxy: ScrollViewProxy) {
        if let firstInitial = model.items.first(where: { item in
            item.status == .initial
        }) {
            proxy.scrollTo(firstInitial.id)
        }
    }
    
    private func scrollToLastItem(using proxy: ScrollViewProxy) {
        if let lastItem = model.items.last {
            proxy.scrollTo(lastItem.id)
        }
    }
    
    @ViewBuilder
    var cancelButton: some View {
        Button(LocalString.common_button_cancel, role: .destructive) {
            model.cancel()
        }
    }
    
    @ViewBuilder
    func runButton(again: Bool) -> some View {
        AsyncButton {
            withAnimation {
                model.start(using: zimFiles.reversed())
            }
        } label: {
#if os(macOS)
            let title: String = again ? "Run again" : "Run"
            Label(title, systemImage: "exclamationmark.bubble")
                .symbolEffect(.bounce, value: model.state == .running)
#else
            let title: String = again ? "Run again" : "Run"
            Text(title)
#endif
        }
#if os(iOS)
        .buttonStyle(.borderless)
#endif
    }
    
#if os(macOS)
    @ViewBuilder
    func emailButton(logs: [String]) -> some View {
        AsyncButton {
            let emailLogs = logs.joined(separator: Email.separator())
            let email = Email(logs: emailLogs)
            email.create()
        } label: {
            Label("Send to Support", systemImage: "paperplane")
                .symbolEffect(.bounce, value: model.state == .running)
        }
    }

    @ViewBuilder
    func saveButton(logs: [String]) -> some View {
        AsyncButton {
            let fileLogs = logs.joined(separator: "\n")
            guard let data = fileLogs.data(using: .utf8) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.log]
            panel.nameFieldStringValue = "\(Diagnostics.fileName(using: Date())).txt"
            if case .OK = panel.runModal(),
               let targetURL = panel.url {
                try? data.write(to: targetURL)
            }
        } label: {
            Label("Save log file", systemImage: "square.and.arrow.down")
                .symbolEffect(.bounce, value: model.state == .running)
        }
    }
#endif
}

#if os(iOS)
@MainActor
private struct DiagnosticReportPreview: View {
    let logs: [String]

    @State private var diagnosticEmailPayload: DiagnosticEmailPayload?
    @State private var diagnosticSharePayload: DiagnosticSharePayload?

    private var report: String {
        logs.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review before sharing")
                .font(.headline)
            Text(
                "This report contains ArkFile version and device details, installed-content and integrity summaries, and recent app logs. Common credentials, account identifiers, email addresses, and local paths are redacted. Nothing is sent unless you choose an action below."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            ScrollView {
                Text(report.isEmpty ? "No diagnostic entries were collected." : report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button {
                    sendDiagnosticEmail()
                } label: {
                    Label("Send to Support", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    shareDiagnosticLog()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .navigationTitle("Review Report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $diagnosticEmailPayload) { payload in
            DiagnosticMailComposeView(payload: payload)
        }
        .sheet(item: $diagnosticSharePayload, onDismiss: removeSharedDiagnosticFile) { payload in
            ActivityViewController(activityItems: [payload.url])
        }
    }

    private func sendDiagnosticEmail() {
        guard MFMailComposeViewController.canSendMail() else {
            shareDiagnosticLog()
            return
        }
        diagnosticEmailPayload = DiagnosticEmailPayload(logs: report)
    }

    private func shareDiagnosticLog() {
        guard let data = report.data(using: .utf8) else { return }
        let exportData = FileExportData(
            data: data,
            fileName: Diagnostics.fileName(using: Date()),
            fileExtension: "txt"
        )
        guard let tempURL = FileExporter.tempFileFrom(exportData: exportData) else { return }
        diagnosticSharePayload = DiagnosticSharePayload(url: tempURL)
    }

    private func removeSharedDiagnosticFile() {
        if let url = diagnosticSharePayload?.url {
            try? FileManager.default.removeItem(at: url)
        }
        diagnosticSharePayload = nil
    }
}

private struct DiagnosticEmailPayload: Identifiable {
    let id = UUID()
    let logs: String
}

private struct DiagnosticSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DiagnosticMailComposeView: UIViewControllerRepresentable {
    let payload: DiagnosticEmailPayload
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([Brand.feedbackEmail])
        controller.setSubject("ArkFile diagnostic report")
        controller.setMessageBody(
            "Please describe what happened above this line.\n\nArkFile diagnostic logs are attached.",
            isHTML: false
        )
        controller.addAttachmentData(
            Data(payload.logs.utf8),
            mimeType: "text/plain",
            fileName: "\(Diagnostics.fileName(using: Date())).txt"
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        @MainActor
        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }
}
#endif
