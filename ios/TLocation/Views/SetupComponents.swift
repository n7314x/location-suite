import SwiftUI

struct SetupGlassPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            panel.glassEffect(in: .rect(cornerRadius: 25))
        } else {
            panel.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        }
    }

    private var panel: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.09), radius: 22, y: 10)
    }
}

struct SetupStatusRow: View {
    let title: String
    let detail: String
    let complete: Bool
    var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, detail: String, complete: Bool, working: Bool = false) {
        self.title = title
        self.detail = detail
        self.complete = complete
        self.working = working
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Group {
                if complete {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(complete ? "ready" : working ? "in progress" : "pending"). \(detail)")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: complete)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: working)
    }
}
