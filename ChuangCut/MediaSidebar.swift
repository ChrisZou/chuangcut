import SwiftUI
import ChuangCutCore

struct MediaSidebar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var thumbnails: ThumbnailStore
    var body: some View {
        VStack(spacing: 0) {
            if let project = model.project {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        if let image = thumbnails.poster { Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() } else { Rectangle().fill(.quaternary) }
                        LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                        Label("\(project.media.width) × \(project.media.height)  ·  \(String(format: "%.0f", project.media.frameRate ?? 0)) fps", systemImage: "film").font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(10)
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                    }.frame(height: 115).clipShape(RoundedRectangle(cornerRadius: 9))
                    Text(project.source.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 7) {
                        Text(timeLabel(project.media.duration)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(timeLabel(model.mapper.editedDuration)).fontWeight(.semibold)
                    }.font(.system(size: 12, design: .monospaced))
                    let saved = project.media.duration - model.mapper.editedDuration
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("−\(String(format: "%.1f", saved))s").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-1)
                        Spacer()
                        Text("\(Int((saved / project.media.duration * 100).rounded()))% saved").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }.foregroundStyle(.teal)
                }.padding(16)
            }
            Divider()
            List {
                ForEach(CutKind.allCases, id: \.self) { kind in
                    let cuts = model.project?.candidates.filter { $0.kind == kind } ?? []
                    Section {
                        ForEach(cuts) { cut in CandidateRow(cut: cut, selected: model.selectedCandidate == cut.id, disabled: model.busy, toggle: { model.toggle(cut.id) }, select: { model.selectCandidate(cut) }) }
                    } header: {
                        HStack(spacing: 7) {
                            Label(kind.title, systemImage: kind.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(kind.tint).padding(.horizontal, 7).padding(.vertical, 4).background(kind.tint.opacity(0.1), in: Capsule())
                            Text("\(cuts.filter(\.enabled).count)/\(cuts.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Toggle("Enable all \(kind.title)", isOn: Binding(get: { !cuts.isEmpty && cuts.allSatisfy(\.enabled) }, set: { model.setAll(kind, enabled: $0) })).labelsHidden().toggleStyle(.checkbox).controlSize(.mini).disabled(cuts.isEmpty || model.busy).help("Enable / disable all \(kind.title)")
                        }.textCase(nil).padding(.vertical, 3)
                    }
                }
            }.listStyle(.sidebar)
        }.background(.bar)
    }
}
private struct CandidateRow: View {
    let cut: CutCandidate
    let selected: Bool
    let disabled: Bool
    let toggle: () -> Void
    let select: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("Enable \(cut.text)", isOn: Binding(get: { cut.enabled }, set: { _ in toggle() })).labelsHidden().toggleStyle(.checkbox).controlSize(.small).disabled(disabled).padding(.top, 2)
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Circle().fill(cut.kind.tint).frame(width: 4, height: 4)
                        Text(String(format: "%.2f – %.2f", cut.sourceStart, cut.sourceEnd)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    Text(cut.kind == .pause ? String(format: "Ⅱ %.1fs", cut.range.duration) : cut.text).font(.system(size: 12)).lineLimit(2).foregroundStyle(cut.enabled ? .primary : .secondary)
                    if cut.isAdjusted == true { Text("Adjusted").font(.system(size: 9, weight: .medium)).foregroundStyle(cut.kind.tint).padding(.horizontal, 5).padding(.vertical, 2).background(cut.kind.tint.opacity(0.1), in: Capsule()) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(cut.reason)
        }.padding(8).background(selected ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor.opacity(0.35) : .clear))
            .onHover { hovering = $0 }.listRowInsets(EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
    }
}
