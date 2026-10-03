import SwiftUI
import AppKit
import Darwin

private struct EditorLineJump: Equatable {
    let id = UUID()
    let line: Int
}

private final class TerraformEditorTextView: NSTextView {
    var saveAction: (() -> Void)?

    private func handleEditorShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "s": saveAction?(); return true
        case "f":
            usesFindBar = true
            let sender = NSMenuItem()
            sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(sender)
            return true
        default: return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditorShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleEditorShortcut(event) { return }
        super.keyDown(with: event)
    }
}

private final class TerraformLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var cachedSource: String?
    private var lineStarts = [0]

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 42
        clientView = textView
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = scrollView?.documentVisibleRect ?? rect
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let origin = textView.textContainerOrigin
        let source = textView.string
        if cachedSource != source {
            cachedSource = source
            let nsSource = source as NSString
            lineStarts = [0]
            var searchStart = 0
            while searchStart < nsSource.length {
                let found = nsSource.range(of: "\n", options: [],
                                           range: NSRange(location: searchStart, length: nsSource.length - searchStart))
                guard found.location != NSNotFound else { break }
                searchStart = NSMaxRange(found)
                lineStarts.append(searchStart)
            }
        }
        let nsSource = source as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let lineStarts = self.lineStarts
        var previousLine: Int?
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, glyphLineRange, _ in
            let chars = layout.characterRange(forGlyphRange: glyphLineRange, actualGlyphRange: nil)
            let offset = min(chars.location, nsSource.length)
            var low = 0, high = lineStarts.count
            while low < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            let line = max(1, low)
            guard line != previousLine else { return }
            previousLine = line
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            let textRect = usedRect.offsetBy(dx: origin.x, dy: origin.y)
            let rulerRect = textView.convert(textRect, to: self)
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8,
                                   y: rulerRect.minY + max(0, (rulerRect.height - size.height) / 2)),
                       withAttributes: attrs)
        }
        if source.isEmpty || source.hasSuffix("\n") {
            let extra = layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            if extra.height > 0 {
                let rulerRect = textView.convert(extra, to: self)
                let label = "\(lineStarts.count)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8,
                                       y: rulerRect.minY + max(0, (rulerRect.height - size.height) / 2)),
                           withAttributes: attrs)
            }
        }
    }
}

private struct TerraformSourceEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let jump: EditorLineJump?
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = TerraformEditorTextView()
        editor.saveAction = onSave
        editor.delegate = context.coordinator
        editor.usesFindBar = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFontPanel = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.drawsBackground = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.setAccessibilityLabel("Terraform source editor")
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = TerraformLineNumberRulerView(scrollView: scroll, textView: editor)
        context.coordinator.apply(text, to: editor)
        editor.setSelectedRange(selection)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        (editor as? TerraformEditorTextView)?.saveAction = onSave
        if editor.string != text {
            context.coordinator.apply(text, to: editor)
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if let jump, context.coordinator.lastJumpID != jump.id {
            context.coordinator.lastJumpID = jump.id
            if let range = ConfigurationModel.sourceRange(forLine: jump.line, in: editor.string) {
                editor.setSelectedRange(range)
                editor.scrollRangeToVisible(range)
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TerraformSourceEditor
        var lastJumpID: UUID?
        private var applying = false

        init(_ parent: TerraformSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.selection = editor.selectedRange()
            applySyntaxColors(to: editor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            parent.selection = editor.selectedRange()
        }

        func apply(_ text: String, to editor: NSTextView) {
            applying = true
            editor.string = text
            applySyntaxColors(to: editor)
            applying = false
        }

        private func applySyntaxColors(to editor: NSTextView) {
            guard let storage = editor.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let selection = editor.selectedRange()
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
            let rules: [(String, NSColor)] = [
                (#"(?m)(#|//).*?$"#, .secondaryLabelColor),
                (#"\"(?:[^\"\\]|\\.)*\""#, .systemRed),
                (#"\b(resource|data|variable|output|provider|terraform|module|locals|moved|import|check|removed)\b"#, .systemPurple),
                (#"\b(var|local|module|path|terraform)\.[A-Za-z0-9_-]+"#, .systemBlue),
                (#"\b[0-9]+(?:\.[0-9]+)?\b"#, .systemOrange)
            ]
            let source = storage.string
            for (pattern, color) in rules {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in expression.matches(in: source, range: full) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
            storage.endEditing()
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            let location = min(selection.location, storage.length)
            let length = min(selection.length, storage.length - location)
            editor.setSelectedRange(NSRange(location: location, length: length))
        }
    }
}

struct ConfigurationPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ConfigurationModel
    @Binding var declarationRequest: ConfigurationDeclarationRequest?
    @State private var showStarter = false
    @State private var starterCreated = false
    @State private var pendingFile: ConfigurationFile?
    @State private var pendingJumpLine: Int?
    @State private var jump: EditorLineJump?
    @State private var showUnsavedDecision = false
    @State private var showWorkspaceDecision = false
    @State private var goToLineText = ""

    init(workspace: Workspace, model: ConfigurationModel,
         declarationRequest: Binding<ConfigurationDeclarationRequest?> = .constant(nil)) {
        self.workspace = workspace
        self.model = model
        self._declarationRequest = declarationRequest
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            if workspace.workingDirectory == nil {
                emptyState(title: "Choose a folder", symbol: "folder", detail: "Open a Terraform workspace to browse and edit its configuration.")
            } else if geometry.size.width < 620 {
                compactFilePicker
                editor(compact: true)
            } else {
                HStack(spacing: 0) {
                    fileSidebar
                    Divider()
                    editor(compact: false)
                }
            }
        }
        }

        .onAppear {
            model.attach(to: workspace)
            model.setVisible(true)
            model.readDiagnostics(from: workspace.textOutput)
            consumeDeclarationRequest()
        }
        .onDisappear { model.setVisible(false) }
        .onChange(of: workspace.workingDirectory) { _ in
            model.attach(to: workspace)
            if !model.isWorkspaceSwitchPending { starterCreated = false }
        }
        .onChange(of: workspace.textOutput) { output in model.readDiagnostics(from: output) }
        .onChange(of: declarationRequest) { _ in
            consumeDeclarationRequest()
        }
        .onChange(of: model.isWorkspaceSwitchPending) { pending in showWorkspaceDecision = pending }
        .sheet(isPresented: $showStarter) { starterPreview }
        .alert("Unsaved Changes", isPresented: $showUnsavedDecision) {
            Button("Save") {
                model.save()
                guard !model.hasUnsavedChanges else { return }
                if let pendingFile { model.selectedFile = pendingFile }
                if let pendingJumpLine { jump = EditorLineJump(line: pendingJumpLine) }
                self.pendingFile = nil
                self.pendingJumpLine = nil
            }
            .disabled(model.hasConflict || workspace.locked || !model.canSaveInCurrentWorkspace)
            Button("Discard Changes", role: .destructive) {
                if let pendingFile { model.selectedFile = pendingFile }
                if let pendingJumpLine { jump = EditorLineJump(line: pendingJumpLine) }
                self.pendingFile = nil
                self.pendingJumpLine = nil
            }
            Button("Cancel", role: .cancel) { pendingFile = nil; pendingJumpLine = nil }
        } message: {
            Text("Save your edits before opening another file, or discard them.")
        }
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh configuration files")
                    .help("Refresh files")
            }
            if let directory = workspace.workingDirectory {
                HStack {
                    Text(directory.lastPathComponent).font(.headline).lineLimit(1)
                    SafeCopyButton(value: directory.path, label: "Copy workspace path")
                }
            }
            List(selection: Binding(get: { model.selectedFile?.id }, set: { value in
                guard let file = model.files.first(where: { $0.id == value }), file != model.selectedFile else { return }
                if model.hasUnsavedChanges { pendingFile = file; showUnsavedDecision = true }
                else { model.selectedFile = file }
            })) {
                ForEach(model.files) { file in
                    HStack {
                        Label(file.displayPath, systemImage: "doc.text")
                            .tag(file.id)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        SafeCopyButton(value: file.url.path, label: "Copy configuration path for \(file.displayPath)")
                    }
                }
            }
            .listStyle(.sidebar)
            if model.files.isEmpty {
                Text("No .tf files yet").font(.callout).foregroundStyle(.secondary)
                Button("Preview a starter configuration…") { showStarter = true }
                    .buttonStyle(.borderless).font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 210, idealWidth: 240, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.15))
    }

    private var compactFilePicker: some View {
        HStack(spacing: 10) {
            if model.files.isEmpty {
                Text("No configuration files").font(.callout).foregroundStyle(.secondary)
                Button("Preview starter…") { showStarter = true }
            } else {
                Picker("Configuration file", selection: Binding(get: { model.selectedFile?.id ?? "" }, set: { id in
                    if let file = model.files.first(where: { $0.id == id }) { requestSelection(file) }
                })) {
                    ForEach(model.files) { file in Text(file.displayPath).tag(file.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Configuration file")
            }
            Spacer(minLength: 0)
            Button { model.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh configuration files")
                .help("Refresh files")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.15))
    }

    private func editor(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if let file = model.selectedFile {
                if compact {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.displayPath).font(.headline).lineLimit(1)
                            if model.hasUnsavedChanges {
                                Label("Unsaved changes", systemImage: "pencil.circle").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 4)
                        SafeCopyButton(value: file.url.path, label: "Copy configuration path")
                        Button { model.save() } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Save configuration")
                            .disabled(!model.hasUnsavedChanges || model.hasConflict || workspace.locked || !model.canSaveInCurrentWorkspace)
                        Menu { editorActions } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("Configuration actions")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.displayPath).font(.headline)
                        Text(file.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    SafeCopyButton(value: file.url.path, label: "Copy configuration path")
                    if model.hasUnsavedChanges {
                        Label("Unsaved changes", systemImage: "pencil.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { editorActions }
                        Menu("Actions") { editorActions }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                }
                Divider()

                TerraformConfigurationContextHelpView(workspace: workspace, configuration: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                HStack(spacing: 8) {
                    Spacer()
                    TextField("Line", text: $goToLineText)
                        .frame(width: 72)
                        .accessibilityLabel("Go to line number")
                        .onSubmit(goToLine)
                    Button("Go to Line", action: goToLine)
                        .disabled(Int(goToLineText) == nil || (Int(goToLineText) ?? 0) < 1)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if model.hasConflict {
                    HStack(spacing: 10) {
                        Label("This file changed outside Habitable.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reload from Disk", action: model.reloadFromDisk)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08))
                }

                VSplitView {
                    TerraformSourceEditor(text: $model.draft, selection: $model.editorSelection, jump: jump, onSave: saveFromEditor)
                        .accessibilityLabel("Terraform source editor")
                        .background(Color(nsColor: .textBackgroundColor))
                        .frame(minHeight: 160, idealHeight: 480, maxHeight: .infinity)
                    resultsPanel
                        .frame(minHeight: 100, idealHeight: 150, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState(title: "No configuration selected", symbol: "curlybraces", detail: "Select a Terraform file or preview a starter configuration.")
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Unsaved Changes in the Previous Folder", isPresented: $showWorkspaceDecision) {
            Button("Discard and Continue", role: .destructive) {
                model.discardAndSwitchWorkspace()
                starterCreated = false
            }
            Button("Keep Editing", role: .cancel) { model.keepEditingPreviousWorkspace() }
        } message: {
            Text("Your edits are still open. Return to the original folder to save them, or discard them to continue in the new workspace.")
        }
    }

    @ViewBuilder private var editorActions: some View {
        if let file = model.selectedFile?.url { ExternalEditorPicker(file: file) }
        Menu {
            ForEach(workspace.declaredTerraformInputs) { declaration in
                Button {
                    model.insertVariableReference(declaration.name)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("var.\(declaration.name)")
                        if let description = declaration.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        } label: {
            Label("Insert variable reference", systemImage: "text.badge.plus")
        }
        .disabled(workspace.declaredTerraformInputs.isEmpty)
        Button { model.formatAndSave() } label: { Label("Format", systemImage: "text.alignleft") }
            .help(model.selectedFile?.name.hasSuffix(".tf.json") == true ? "Terraform fmt formats HCL files. JSON configuration can still be edited, saved, and validated." : "Format and save this configuration file")
            .disabled(model.isFormatting || workspace.locked || model.hasConflict || !model.canSaveInCurrentWorkspace || model.selectedFile?.name.hasSuffix(".tf.json") == true)
        Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasUnsavedChanges || model.hasConflict || workspace.locked || !model.canSaveInCurrentWorkspace)
    }
    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Validation")
                    .font(.subheadline.weight(.semibold))
                if model.validationActivity == .running {
                    ProgressView().controlSize(.small)
                    Text("Validating…").font(.caption).foregroundStyle(.secondary)
                } else if model.validationActivity == .scheduled {
                    Text("Validation queued").font(.caption).foregroundStyle(.secondary)
                } else if workspace.locked {
                    ProgressView().controlSize(.small)
                    Text("Terraform is running…").font(.caption).foregroundStyle(.secondary)
                } else if workspace.isValid {
                    Label("Saved configuration valid", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if workspace.errorMessage != nil || !model.diagnostics.isEmpty {
                    Label("Needs attention", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not validated").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { workspace.validate() } label: { Label("Validate", systemImage: "checkmark.seal") }
                    .disabled(workspace.locked)
                    .help("Validate the saved workspace configuration")
            }
            if model.hasUnsavedChanges {
                Text("Save to validate your changes.").font(.callout).foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = workspace.errorMessage, model.diagnostics.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.diagnostics) { diagnostic in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: diagnostic.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(diagnostic.message).font(.callout.weight(.medium))
                                if let file = diagnostic.file {
                                    HStack {
                                        Button {
                                            if let match = model.file(matching: file) {
                                                requestSelection(match, line: diagnostic.line)
                                            } else {
                                                model.message = file.contains(".terraform") || file.contains(".git") || file.contains("vendor")
                                                    ? "This diagnostic points to downloaded module or provider files. Those cache files are unavailable for editing."
                                                    : "This diagnostic source is outside the browsable local workspace files."
                                            }
                                        } label: {
                                            Label("\(file)\(diagnostic.line.map { ":\($0)" } ?? "")", systemImage: "arrow.up.left")
                                                .font(.caption.monospaced())
                                        }
                                        .buttonStyle(.link)
                                        SafeCopyButton(value: "\(file)\(diagnostic.line.map { ":\($0)" } ?? "")",
                                                       label: "Copy diagnostic source location")
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private var starterPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(StarterConfiguration.local.title).font(.title2.weight(.semibold))
                    Text("A small local example using Terraform's built-in terraform_data resource. It needs no cloud account or provider install.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { showStarter = false }
            }
            Text("Files to create: main.tf").font(.subheadline.weight(.medium))
            ScrollView {
                Text(StarterConfiguration.local.files[0].1)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Creating this file will make an explicit change in the selected folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Create main.tf") { createStarter() }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.workingDirectory == nil || starterCreated)
            }
            if starterCreated { Label("main.tf created", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 520)
    }

    private func emptyState(title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestSelection(_ file: ConfigurationFile, line: Int? = nil) {
        if file == model.selectedFile {
            if let line { jump = EditorLineJump(line: line) }
            return
        }
        if model.hasUnsavedChanges { pendingFile = file; pendingJumpLine = line; showUnsavedDecision = true }
        else {
            model.selectedFile = file
            if let line { jump = EditorLineJump(line: line) }
        }
    }

    private func goToLine() {
        guard let line = Int(goToLineText), line > 0,
              ConfigurationModel.sourceRange(forLine: line, in: model.draft) != nil else {
            let lineCount = model.draft.utf8.reduce(into: 1) { if $1 == 0x0A { $0 += 1 } }
            model.message = "Enter a line from 1 to \(lineCount)."
            return
        }
        jump = EditorLineJump(line: line)
    }

    private func saveFromEditor() {
        guard !workspace.locked, !model.hasConflict, model.canSaveInCurrentWorkspace else { return }
        model.save()
    }

    private func consumeDeclarationRequest() {
        guard let request = declarationRequest else { return }
        guard let file = model.file(matching: request.file) else {
            declarationRequest = nil
            model.message = "The declaration file is no longer available in this workspace."
            return
        }
        requestSelection(file, line: request.line)
        declarationRequest = nil
    }

    private func createStarter() {
        guard let directory = workspace.workingDirectory else { return }
        let files = StarterConfiguration.local.files
        var createdURLs: [URL] = []
        do {
            for (name, contents) in files {
                let url = directory.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    model.message = "\(name) already exists. Nothing was overwritten."
                    return
                }
            }
            for (name, contents) in files {
                let path = directory.appendingPathComponent(name).path
                let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let createdURL = directory.appendingPathComponent(name)
                createdURLs.append(createdURL)
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try handle.write(contentsOf: Data(contents.utf8))
                try handle.close()
            }
            workspace.isValid = false
            do { try workspace.configurationDidSave() }
            catch { model.message = "The starter file was created, but existing plans could not be safely invalidated: \(error.localizedDescription)" }
            starterCreated = true
            model.attach(to: workspace)
            model.selectedFile = model.files.first { $0.name == "main.tf" }
            model.message = "Starter file created. Review it, then initialize and validate when you are ready."
        } catch {
            for url in createdURLs { try? FileManager.default.removeItem(at: url) }
            model.message = "Could not create the starter file: \(error.localizedDescription)"
        }
    }
}

/// The main action uses the remembered choice; the menu changes it explicitly.
struct ExternalEditorPicker: View {
    let file: URL
    var targetLabel = "file"
    @EnvironmentObject private var editors: ExternalEditorStore

    var body: some View {
        Menu {
            if let selected = editors.selected {
                Button("Open in \(selected.name)") { editors.open(file) }
                Divider()
            }
            ForEach(editors.editors) { editor in
                Button { editors.open(file, with: editor) } label: {
                    if editor.id == editors.selectedID {
                        Label(editor.name, systemImage: "checkmark")
                    } else { Text(editor.name) }
                }
            }
            Divider()
            Button("Choose Other Editor…") { editors.chooseApplication() }
            Button("Refresh Editors") { editors.refresh() }
        } label: {
            Label(editors.selected.map { "Open in \($0.name)" } ?? "Open in Editor", systemImage: "arrow.up.forward.square")
        } primaryAction: {
            if editors.selected != nil { editors.open(file) }
            else { editors.chooseApplication() }
        }
        .help(editors.selected.map { "Open \(targetLabel) in \($0.name). Use the menu to choose another editor." }
              ?? "Choose an editor to open \(targetLabel).")
        .accessibilityLabel(editors.selected.map { "Open \(targetLabel) in \($0.name)" } ?? "Open \(targetLabel) in Editor")
        .alert("Unable to Open Editor", isPresented: Binding(get: { editors.error != nil }, set: { if !$0 { editors.error = nil } })) {
            Button("OK") { editors.error = nil }
        } message: { Text(editors.error ?? "") }
    }
}
