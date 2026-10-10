#if os(macOS)
import SwiftLensCore
import SwiftUI

extension SyntaxTreeNode {
    var optionalChildren: [SyntaxTreeNode]? { children.isEmpty ? nil : children }

    var displayLabel: String {
        var label = ""
        if let childName { label += "\(childName): " }
        if let indexInParent { label += "[\(indexInParent)] " }
        if let token { return label + "\(token.kind) \(token.text.debugDescription)" }
        return label + kind + (summary.map { " ‹\($0)›" } ?? "")
    }
}

struct SyntaxTreeResultView: View {
    @ObservedObject var model: AppModel
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter by kind or text", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Tokens", isOn: $model.treeShowsTokens)
                    .onChange(of: model.treeShowsTokens) { _ in model.buildTree() }
                Spacer()
                if let tree = model.tree { Text("\(tree.subtreeCount) nodes").font(.caption).foregroundStyle(.secondary) }
            }
            if !model.cursorPath.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.cursorPath) { node in
                            Button(node.token == nil ? node.kind.replacingOccurrences(of: "Syntax", with: "") : node.token!.text) {
                                model.select(node: node)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            if node.id != model.cursorPath.last?.id { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                }
            }
            HSplitView {
                treeList.frame(minWidth: 260)
                NodeInspector(node: selectedNode, onSelect: { model.select(node: $0) }).frame(minWidth: 240, idealWidth: 300)
            }
        }
    }

    private var selectedNode: SyntaxTreeNode? {
        guard let id = model.selectedNodeID else { return nil }
        return model.tree?.find(id: id)
    }

    @ViewBuilder private var treeList: some View {
        if let tree = model.tree {
            if filter.isEmpty {
                List(selection: $model.selectedNodeID) {
                    OutlineGroup([tree], children: \.optionalChildren) { node in
                        NodeRow(node: node).tag(node.id)
                    }
                }
                .onChange(of: model.selectedNodeID) { id in
                    if let id, let node = model.tree?.find(id: id) { model.select(node: node) }
                }
            } else {
                let matches = tree.flattened().filter {
                    $0.kind.localizedCaseInsensitiveContains(filter) || ($0.token?.text.localizedCaseInsensitiveContains(filter) ?? false) || ($0.summary?.localizedCaseInsensitiveContains(filter) ?? false)
                }
                List(matches, selection: $model.selectedNodeID) { node in
                    NodeRow(node: node).tag(node.id)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct NodeRow: View {
    let node: SyntaxTreeNode

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(node.displayLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(node.isMissing ? .secondary : .primary)
                .lineLimit(1)
            if node.hasError && node.token == nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.caption) }
            Spacer()
            Text("\(node.span.start.line):\(node.span.start.column)").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var color: Color {
        switch node.category {
        case .declaration: .purple
        case .expression: .blue
        case .statement: .orange
        case .type: .teal
        case .pattern: .pink
        case .token: .gray
        case .collection: .brown
        case .other: .secondary
        }
    }
}

struct NodeInspector: View {
    let node: SyntaxTreeNode?
    var onSelect: (SyntaxTreeNode) -> Void

    var body: some View {
        if let node {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(node.kind).font(.title3.bold()).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        row("Category", node.category.rawValue)
                        if let childName = node.childName { row("Property", childName) }
                        row("Range", "\(node.span.start.line):\(node.span.start.column) – \(node.span.end.line):\(node.span.end.column)")
                        row("UTF-8 offsets", "\(node.span.start.offset)..<\(node.span.end.offset)")
                        if let token = node.token {
                            row("Token kind", token.kind)
                            row("Text", token.text.debugDescription)
                            row("Leading trivia", token.leadingTrivia.isEmpty ? "—" : token.leadingTrivia)
                            row("Trailing trivia", token.trailingTrivia.isEmpty ? "—" : token.trailingTrivia)
                            row("Presence", token.presence)
                        }
                        row("Has error", node.hasError ? "yes" : "no")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Access path").font(.headline)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.accessPath, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .controlSize(.small)
                        }
                        Text(node.accessPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        Text("Paste into your macro to reach this node from the root.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !node.children.isEmpty {
                        Text("Children").font(.headline)
                        ForEach(node.children) { child in
                            Button(child.displayLabel) { onSelect(child) }
                                .buttonStyle(.link)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a node, or move the cursor in the editor.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).font(.caption)
            Text(value).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
        }
    }
}
#endif
