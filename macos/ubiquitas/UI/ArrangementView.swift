import SwiftUI
import UniformTypeIdentifiers

/// The screens as tiles to drag into place; the hub snaps a dropped tile against its nearest neighbour.
struct ArrangementView: View {
    @ObservedObject var hub: Hub
    @State private var dragging: String?
    @State private var offset = CGSize.zero
    @State private var dropTarget: String?

    var body: some View {
        GeometryReader { geo in
            let box = hub.screens.reduce(CGRect.null) { $0.union($1.rect) }
            let scale = box.isNull ? 1 : min(geo.size.width / box.width, geo.size.height / box.height) * 0.88
            let ox = (geo.size.width - box.width * scale) / 2 - box.minX * scale
            let oy = (geo.size.height - box.height * scale) / 2 - box.minY * scale
            ZStack {
                ForEach(hub.screens) { s in
                    let moving = dragging == s.name
                    tile(s)
                        .frame(width: CGFloat(s.w) * scale - 2, height: CGFloat(s.h) * scale - 2)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { dragging = s.name; offset = $0.translation }
                            .onEnded {
                                hub.move(s.name, x: s.x + Int(($0.translation.width / scale).rounded()),
                                         y: s.y + Int(($0.translation.height / scale).rounded()))
                                dragging = nil
                                offset = .zero
                            })
                        .onDrop(of: [.fileURL], isTargeted: Binding(get: { dropTarget == s.name },
                                                                    set: { dropTarget = $0 ? s.name : (dropTarget == s.name ? nil : dropTarget) })) { providers in
                            guard s.online, s.name != hub.me else { return false }
                            for p in providers {
                                _ = p.loadObject(ofClass: URL.self) { url, _ in
                                    if let url { DispatchQueue.main.async { hub.sendFile(url, to: s.name) } }
                                }
                            }
                            return true
                        }
                        .position(x: ox + (CGFloat(s.x) + CGFloat(s.w) / 2) * scale + (moving ? offset.width : 0),
                                  y: oy + (CGFloat(s.y) + CGFloat(s.h) / 2) * scale + (moving ? offset.height : 0))
                        .zIndex(moving ? 1 : 0)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(s.name), \(s.online ? "online" : "offline")\(s.name == hub.active ? ", has input" : "")")
                }
            }
            .animation(.smooth(duration: 0.25), value: hub.screens)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tile(_ s: Screen) -> some View {
        let isActive = s.name == hub.active
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return shape
            .fill(isActive ? Color.accentColor.opacity(0.85)
                  : dropTarget == s.name ? Color.accentColor.opacity(0.35)
                  : Color.primary.opacity(s.online ? 0.12 : 0.04))
            .overlay(shape.strokeBorder(Color.primary.opacity(s.online ? 0.18 : 0.25),
                                        style: StrokeStyle(lineWidth: 1, dash: s.online ? [] : [3, 2])))
            .overlay(
                VStack(spacing: 1) {
                    Image(systemName: s.name == hub.me ? "laptopcomputer" : "desktopcomputer")
                        .font(.system(size: 11))
                    Text(s.name).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(3)
                .foregroundStyle(isActive ? Color.white : s.online ? Color.primary : Color.secondary))
            .shadow(color: .black.opacity(dragging == s.name ? 0.25 : 0), radius: 6, y: 2)
    }
}
