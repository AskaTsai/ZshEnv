import SwiftUI
import UniformTypeIdentifiers
import Security

private let beginMarker = "# >>> ZshEnv managed variables >>>"
private let endMarker = "# <<< ZshEnv managed variables <<<"

struct EnvVariable: Identifiable, Codable, Equatable {
    enum Origin: String, Codable { case managed, existing }
    var id = UUID()
    var name = ""
    var value = ""
    var note = ""
    var enabled = true
    // Existing zsh expressions are kept verbatim until the value is edited.
    var rawExpression: String? = nil
    var origin: Origin = .managed
    var originalLineIndex: Int? = nil
    var originalLine: String? = nil
    var originalNoteLineIndex: Int? = nil
}

@MainActor
final class EnvStore: ObservableObject {
    @Published var variables: [EnvVariable] = []
    @Published var selectedID: UUID?
    @Published var status = "就绪"
    @Published var showingError = false
    @Published var errorMessage = ""

    private let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    private var lastAppliedNames = Set<String>()
    private var loadedFingerprint = ""
    private var loadedExisting: [UUID: EnvVariable] = [:]

    init() { load() }

    func load() {
        do {
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            loadedFingerprint = ShellValueLogic.fingerprint(text)
            let managed = parseManagedBlock(text)
            let managedNames = Set(managed.map(\.name))
            let imported = parseExistingExports(text).filter { !managedNames.contains($0.variable.name) }
            variables = managed + imported.map(\.variable)
            loadedExisting = Dictionary(uniqueKeysWithValues: imported.map { ($0.variable.id, $0.variable) })
            lastAppliedNames = Set(variables.filter(\.enabled).map(\.name))
            selectedID = variables.first?.id
            status = variables.isEmpty ? "尚未添加变量" : "已读取 \(variables.count) 个变量" + (imported.isEmpty ? "" : "（含现有配置 \(imported.count) 个）")
        }
    }

    func add() {
        let item = EnvVariable()
        variables.append(item)
        selectedID = item.id
    }

    func duplicate(_ item: EnvVariable) {
        var copy = item
        copy.id = UUID()
        copy.name += "_COPY"
        copy.origin = .managed
        copy.originalLineIndex = nil
        copy.originalLine = nil
        copy.originalNoteLineIndex = nil
        if let index = variables.firstIndex(of: item) { variables.insert(copy, at: index + 1) }
        selectedID = copy.id
    }

    func remove(_ item: EnvVariable) {
        variables.removeAll { $0.id == item.id }
        selectedID = variables.first?.id
    }

    func move(_ source: UUID, before target: UUID) {
        guard source != target,
              let from = variables.firstIndex(where: { $0.id == source }),
              let to = variables.firstIndex(where: { $0.id == target }),
              variables[from].origin == .managed,
              variables[to].origin == .managed else { return }
        var candidate = variables
        let item = candidate.remove(at: from)
        candidate.insert(item, at: from < to ? to - 1 : to)
        do {
            try validateDependencies(candidate)
            variables = candidate
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
            status = "已阻止可能破坏引用关系的排序"
        }
    }

    func save() {
        do {
            let cleaned = try validatedVariables()
            let oldText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            guard ShellValueLogic.fingerprint(oldText) == loadedFingerprint else {
                throw AppError.message(".zshrc 在应用打开后已被其他程序修改。为避免覆盖新内容，请点击“重新加载”后再编辑。")
            }
            try validateDependencies(cleaned)
            let updatedText = updateExistingLines(in: oldText, with: cleaned)
            let newText = replaceManagedBlock(in: updatedText, with: renderManaged(cleaned))
            try validateZsh(newText)
            try backupIfNeeded(oldText)
            try newText.write(to: fileURL, atomically: true, encoding: .utf8)
            applyToLaunchctl(cleaned)
            variables = cleaned
            lastAppliedNames = Set(cleaned.filter(\.enabled).map(\.name))
            loadedFingerprint = ShellValueLogic.fingerprint(newText)
            refreshExistingRecords(afterSaving: newText)
            status = "已保存并生效 · \(timeString())"
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
            status = "保存失败"
        }
    }

    private func validatedVariables() throws -> [EnvVariable] {
        var seen = Set<String>()
        return try variables.map { raw in
            var item = raw
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                throw AppError.message("变量名“\(item.name)”无效。只能包含字母、数字和下划线，且不能以数字开头。")
            }
            guard seen.insert(item.name).inserted else { throw AppError.message("变量名“\(item.name)”重复。") }
            return item
        }
    }

    func reload() { load() }

    func dependencies(of item: EnvVariable) -> [String] {
        ShellValueLogic.references(in: item.rawExpression ?? item.value)
    }

    func assignmentPreview(for item: EnvVariable) -> String {
        "export \(item.name)=\(item.rawExpression ?? ShellValueLogic.quote(item.value))"
    }

    private func parseManagedBlock(_ text: String) -> [EnvVariable] {
        guard let begin = text.range(of: beginMarker),
              let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) else { return [] }
        let body = text[begin.upperBound..<end.lowerBound]
        var result: [EnvVariable] = []
        var note = ""
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# note: ") { note = String(line.dropFirst(8)); continue }
            let enabled: Bool
            let expression: String
            if line.hasPrefix("export ") { enabled = true; expression = String(line.dropFirst(7)) }
            else if line.hasPrefix("# disabled: export ") { enabled = false; expression = String(line.dropFirst(19)) }
            else { continue }
            guard let equal = expression.firstIndex(of: "=") else { continue }
            let name = String(expression[..<equal])
            let encoded = String(expression[expression.index(after: equal)...])
            result.append(EnvVariable(name: name, value: ShellValueLogic.decode(encoded), note: note, enabled: enabled, origin: .managed))
            note = ""
        }
        return result
    }

    private func parseExistingExports(_ text: String) -> [(variable: EnvVariable, line: String)] {
        var results: [(EnvVariable, String)] = []
        var insideManagedBlock = false
        let lines = text.components(separatedBy: .newlines)
        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == beginMarker { insideManagedBlock = true; continue }
            if line == endMarker { insideManagedBlock = false; continue }
            guard !insideManagedBlock else { continue }
            let enabled: Bool
            let expression: String
            if line.hasPrefix("export ") { enabled = true; expression = String(line.dropFirst(7)) }
            else if line.hasPrefix("# disabled: export ") { enabled = false; expression = String(line.dropFirst(19)) }
            else { continue }
            guard let equal = expression.firstIndex(of: "=") else { continue }
            let name = String(expression[..<equal]).trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            let rhs = String(expression[expression.index(after: equal)...])
            let noteLineIndex: Int?
            let note: String
            if lineIndex > 0, lines[lineIndex - 1].trimmingCharacters(in: .whitespaces).hasPrefix("# zshenv-note: ") {
                noteLineIndex = lineIndex - 1
                note = String(lines[lineIndex - 1].trimmingCharacters(in: .whitespaces).dropFirst(15))
            } else { noteLineIndex = nil; note = "" }
            let variable = EnvVariable(name: name, value: ShellValueLogic.decode(rhs), note: note, enabled: enabled, rawExpression: rhs, origin: .existing, originalLineIndex: lineIndex, originalLine: rawLine, originalNoteLineIndex: noteLineIndex)
            // zsh permits repeated exports; show the final assignment while leaving
            // earlier assignments in place because later expressions may reference them.
            results.removeAll { $0.0.name == name }
            results.append((variable, line))
        }
        return results
    }

    private func renderManaged(_ items: [EnvVariable]) -> String {
        var lines = [beginMarker, "# Generated by ZshEnv. Edit with care."]
        for item in items where item.origin == .managed {
            if !item.note.isEmpty { lines.append("# note: " + item.note.replacingOccurrences(of: "\n", with: " ")) }
            let assignment = assignmentPreview(for: item)
            lines.append(item.enabled ? assignment : "# disabled: \(assignment)")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    private func updateExistingLines(in text: String, with items: [EnvVariable]) -> String {
        var lines = text.components(separatedBy: .newlines)
        let currentByID = Dictionary(uniqueKeysWithValues: items.filter { $0.origin == .existing }.map { ($0.id, $0) })
        for (id, original) in loadedExisting {
            guard let lineIndex = original.originalLineIndex, lines.indices.contains(lineIndex) else { continue }
            if let item = currentByID[id] {
                let expression = item.rawExpression ?? ShellValueLogic.quote(item.value)
                let assignment = "export \(item.name)=\(expression)"
                let rendered = item.enabled ? assignment : "# disabled: \(assignment)"
                if let noteIndex = original.originalNoteLineIndex, lines.indices.contains(noteIndex) {
                    lines[noteIndex] = item.note.isEmpty ? "" : "# zshenv-note: \(item.note.replacingOccurrences(of: "\n", with: " "))"
                    lines[lineIndex] = rendered
                } else if item.note.isEmpty {
                    lines[lineIndex] = rendered
                } else {
                    lines[lineIndex] = "# zshenv-note: \(item.note.replacingOccurrences(of: "\n", with: " "))\n\(rendered)"
                }
            } else {
                if let noteIndex = original.originalNoteLineIndex, lines.indices.contains(noteIndex) { lines[noteIndex] = "" }
                lines[lineIndex] = ""
            }
        }
        return lines.joined(separator: "\n")
    }

    private func validateDependencies(_ items: [EnvVariable]) throws {
        let managed = items.filter { $0.origin == .managed }
        let existingPositions = Dictionary(uniqueKeysWithValues: items.filter { $0.origin == .existing }.compactMap { item in item.originalLineIndex.map { (item.name, $0) } })
        let managedBlockLine = managedBlockStartLine()
        let dependencyItems = managed.map { (name: $0.name, expression: $0.rawExpression ?? $0.value) }
        if let violation = ShellValueLogic.dependencyOrderViolation(in: dependencyItems) {
            throw AppError.message("“\(violation.consumer)”引用了“\(violation.dependency)”，必须排在它之后。已保留原顺序。")
        }
        for item in managed {
            for dependency in dependencies(of: item) where dependency != item.name {
                if let definitionLine = existingPositions[dependency], definitionLine > managedBlockLine {
                    throw AppError.message("“\(item.name)”引用的“\(dependency)”在 .zshrc 的托管区块之后才定义，当前顺序无法正确展开。")
                }
            }
        }
        for item in items where item.origin == .existing {
            guard let original = loadedExisting[item.id],
                  item.rawExpression == nil || item.name != original.name,
                  let itemLine = item.originalLineIndex else { continue }
            for dependency in dependencies(of: item) where dependency != item.name {
                if let definitionLine = existingPositions[dependency], definitionLine > itemLine {
                    throw AppError.message("“\(item.name)”引用的“\(dependency)”在它之后才定义。为保护 .zshrc 上下关系，无法保存此修改。")
                }
                if managed.contains(where: { $0.name == dependency }), itemLine < managedBlockLine {
                    throw AppError.message("“\(item.name)”位于托管区块之前，不能引用之后才定义的“\(dependency)”。")
                }
            }
        }
    }

    private func managedBlockStartLine() -> Int {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return text.components(separatedBy: .newlines).firstIndex { $0.trimmingCharacters(in: .whitespaces) == beginMarker } ?? Int.max
    }

    private func refreshExistingRecords(afterSaving text: String) {
        let parsed = parseExistingExports(text)
        let byName = Dictionary(uniqueKeysWithValues: parsed.map { ($0.variable.name, $0.variable) })
        for index in variables.indices where variables[index].origin == .existing {
            if let refreshed = byName[variables[index].name] {
                var item = refreshed
                item.id = variables[index].id
                variables[index] = item
            }
        }
        loadedExisting = Dictionary(uniqueKeysWithValues: variables.filter { $0.origin == .existing }.map { ($0.id, $0) })
    }

    private func replaceManagedBlock(in text: String, with block: String) -> String {
        if let begin = text.range(of: beginMarker), let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) {
            var output = text
            output.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
            return output.hasSuffix("\n") ? output : output + "\n"
        }
        let prefix = text.isEmpty ? "" : (text.hasSuffix("\n") ? text + "\n" : text + "\n\n")
        return prefix + block + "\n"
    }

    private func validateZsh(_ text: String) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zshenv-\(UUID().uuidString).zsh")
        try text.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", temp.path]
        process.standardError = pipe
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知语法错误"
            throw AppError.message(".zshrc 语法检查未通过：\n\(message)")
        }
    }

    private func backupIfNeeded(_ oldText: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(".zshrc.zshenv-backup-\(formatter.string(from: Date()))")
        try oldText.write(to: backup, atomically: true, encoding: .utf8)
    }

    private func applyToLaunchctl(_ items: [EnvVariable]) {
        let active = Dictionary(uniqueKeysWithValues: items.filter(\.enabled).map { ($0.name, effectiveValue(for: $0)) })
        for name in lastAppliedNames.subtracting(active.keys) { runLaunchctl(["unsetenv", name]) }
        for (name, value) in active { runLaunchctl(["setenv", name, value]) }
        let source = Process()
        source.executableURL = URL(fileURLWithPath: "/bin/zsh")
        source.arguments = ["-lc", "source ~/.zshrc"]
        try? source.run(); source.waitUntilExit()
    }

    private func effectiveValue(for item: EnvVariable) -> String {
        guard item.rawExpression != nil else { return item.value }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "source ~/.zshrc >/dev/null 2>&1; print -rn -- $\(item.name)"]
        process.standardOutput = pipe
        do { try process.run(); process.waitUntilExit() } catch { return item.value }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? item.value
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        try? process.run(); process.waitUntilExit()
    }

    private func timeString() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date()) }
}

enum AppError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }

struct VariableRow: View {
    @Binding var item: EnvVariable
    let selected: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onMove: (UUID, UUID) -> Void
    let allowsReordering: Bool
    @State private var isTargeted = false

    private var rowContent: some View {
        HStack(spacing: 12) {
            if item.origin == .managed {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .opacity(allowsReordering ? 1 : 0.35)
                    .help(allowsReordering ? "拖动排序；不能移动到其依赖变量之前" : "清空搜索后可调整变量顺序")
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("为保护 .zshrc 上下关系，此变量保持原位置")
            }
            Toggle("", isOn: $item.enabled).labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.isEmpty ? "新变量" : item.name).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                Text(item.note.isEmpty ? item.value : item.note).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu { Button("复制", action: onDuplicate); Divider(); Button("删除", role: .destructive, action: onDelete) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.13) : (isTargeted ? Color.accentColor.opacity(0.07) : .clear)))
        .contentShape(Rectangle()).onTapGesture(perform: onSelect)
    }

    @ViewBuilder var body: some View {
        if item.origin == .managed && allowsReordering {
            rowContent
                .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
                .onDrop(of: [UTType.text], isTargeted: $isTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let text = object as? String, let source = UUID(uuidString: text) else { return }
                        DispatchQueue.main.async { onMove(source, item.id) }
                    }
                    return true
                }
        } else {
            rowContent
        }
    }
}

struct ContentView: View {
    @StateObject private var store = EnvStore()
    @State private var searchText = ""
    var selectedIndex: Int? { store.variables.firstIndex { $0.id == store.selectedID } }

    private var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleVariables: [EnvVariable] {
        store.variables.filter {
            ShellValueLogic.matchesSearch(searchText, name: $0.name, value: $0.value, note: $0.note)
        }
    }

    private func reconcileSelection() {
        store.selectedID = ShellValueLogic.reconciledSelection(current: store.selectedID, visibleIDs: visibleVariables.map(\.id))
    }

    private func addVariable() {
        searchText = ""
        store.add()
    }

    private func valueBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { store.variables[index].value },
            set: { newValue in
                store.variables[index].value = newValue
                store.variables[index].rawExpression = nil
            }
        )
    }

    private func generateSecret(length: Int, at index: Int) {
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            store.errorMessage = "系统安全随机数生成失败，请稍后重试。"
            store.showingError = true
            return
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        store.variables[index].value = String(bytes.map { alphabet[Int($0) & 63] })
        store.variables[index].rawExpression = nil
        store.status = "已生成 \(length) 位安全随机口令，保存后生效"
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack { Text("环境变量").font(.title2.bold()); Spacer(); Button { addVariable() } label: { Image(systemName: "plus") }.keyboardShortcut("n") }
                    .padding(16)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索 key、value 或备注", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("清除搜索")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                Divider()
                if store.variables.isEmpty {
                    EmptyState(title: "还没有变量", icon: "terminal", subtitle: "点击右上角 + 添加第一个环境变量")
                } else if visibleVariables.isEmpty {
                    EmptyState(title: "未找到匹配变量", icon: "magnifyingglass", subtitle: "尝试搜索其他 key、value 或备注")
                } else {
                    ScrollView { LazyVStack(spacing: 3) {
                        ForEach($store.variables) { $item in
                            if ShellValueLogic.matchesSearch(searchText, name: item.name, value: item.value, note: item.note) {
                                VariableRow(item: $item, selected: store.selectedID == item.id, onSelect: { store.selectedID = item.id }, onDuplicate: { store.duplicate(item) }, onDelete: { store.remove(item) }, onMove: store.move, allowsReordering: !hasActiveSearch)
                            }
                        }
                    }.padding(8) }
                }
                Divider(); HStack { Circle().fill(Color.green).frame(width: 7, height: 7); Text(store.status).font(.caption).foregroundStyle(.secondary); Spacer() }.padding(12)
            }.navigationSplitViewColumnWidth(min: 270, ideal: 320)
        } detail: {
            if let index = selectedIndex {
                Form {
                    Section("变量") {
                        TextField("变量名，例如 JAVA_HOME", text: $store.variables[index].name).font(.system(.body, design: .monospaced))
                        TextField("变量值", text: valueBinding(at: index), axis: .vertical).font(.system(.body, design: .monospaced)).lineLimit(3...8)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.variables[index].origin == .existing ? ".zshrc 原有配置 · 保持原位置" : "ZshEnv 管理配置 · 可安全拖动排序")
                                .font(.caption).foregroundStyle(store.variables[index].origin == .existing ? Color.orange : Color.secondary)
                            let dependencies = store.dependencies(of: store.variables[index])
                            if !dependencies.isEmpty {
                                Label("依赖于：\(dependencies.joined(separator: ", "))。调整顺序可能改变展开结果。", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text(store.assignmentPreview(for: store.variables[index]))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        HStack {
                            Menu {
                                Button("24 位") { generateSecret(length: 24, at: index) }
                                Button("32 位（推荐）") { generateSecret(length: 32, at: index) }
                                Button("48 位") { generateSecret(length: 48, at: index) }
                            } label: {
                                Label("生成随机口令", systemImage: "key.fill")
                            }
                            .menuStyle(.borderlessButton)
                            Spacer()
                            Text("使用系统安全随机源").font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("启用此变量", isOn: $store.variables[index].enabled)
                    }
                    Section("备注") { TextField("记录用途、来源或注意事项", text: $store.variables[index].note, axis: .vertical).lineLimit(3...6) }
                    Section { Text("保存时会备份 ~/.zshrc、执行 zsh 语法检查，并同步到 launchctl。新终端和之后启动的应用会读取最新值。") .font(.caption).foregroundStyle(.secondary) }
                }.formStyle(.grouped).padding(.horizontal, 14)
            } else { EmptyState(title: "选择一个变量", icon: "slider.horizontal.3", subtitle: "在左侧选择或新建变量") }
        }
        .toolbar {
            ToolbarItem { Button { store.reload() } label: { Label("重新加载", systemImage: "arrow.clockwise") } }
            ToolbarItem(placement: .primaryAction) { Button("保存并生效") { store.save() }.keyboardShortcut("s") }
        }
        .alert("无法保存", isPresented: $store.showingError) { Button("好", role: .cancel) {} } message: { Text(store.errorMessage) }
        .onChange(of: searchText) { _ in reconcileSelection() }
        .onChange(of: store.variables) { _ in reconcileSelection() }
        .frame(minWidth: 820, minHeight: 540)
    }
}

struct EmptyState: View {
    let title: String
    let icon: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main
struct ZshEnvApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.titleBar)
        Settings { Text("ZshEnv 管理 ~/.zshrc 中的独立区块。") .padding(30) }
    }
}
