import SwiftUI

struct TabBarView: View {
    @ObservedObject var tabs: TabsViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.documents.enumerated()), id: \.element.id) { index, document in
                    TabButton(
                        title: document.displayName,
                        isActive: index == tabs.activeIndex,
                        onSelect: { tabs.activate(at: index) },
                        onClose: { tabs.close(at: index) }
                    )
                }
            }
        }
        .frame(height: 32)
        .background(.bar)
    }
}

private struct TabButton: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isCloseHovering: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .font(.system(size: 12))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isCloseHovering ? Color.primary.opacity(0.1) : Color.clear)
            .clipShape(Circle())
            .onHover { isCloseHovering = $0 }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
