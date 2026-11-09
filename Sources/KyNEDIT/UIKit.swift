import SwiftUI
import AppKit

// Éléments d'interface communs (style Socle, plat et sombre) : tailles et alignements identiques dans tous les onglets.
enum UI {
    static let rowHeight: CGFloat = 28
    static let labelWidth: CGFloat = 112
    static let gutter: CGFloat = 16
}

/// Carte : titre en petites capitales, contenu aligné à gauche.
struct SCard<C: View>: View {
    let title: String?
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title.uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle).lineLimit(1) }
            content()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .topLeading).background(Socle.surface, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Ligne « libellé + contrôle » : libellé de largeur fixe, contrôle aligné à gauche, centrés dans la hauteur.
struct SRow<C: View>: View {
    let label: String
    @ViewBuilder var content: () -> C
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).frame(width: UI.labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: UI.rowHeight)
    }
}

/// Liste déroulante pleine largeur.
struct SDropdown<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var body: some View {
        Menu { ForEach(items, id: \.self) { i in Button(label(i)) { selection = i } } } label: { SDropdownLabel(text: label(selection)) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

struct SDropdownLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text("⌄").foregroundColor(Socle.subtle)
        }
        .font(.system(size: 12)).foregroundColor(Socle.text)
        .padding(.horizontal, 10).frame(height: 26).frame(maxWidth: .infinity)
        .background(Socle.control, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SCheck: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(isOn ? "☑" : "☐").foregroundColor(Socle.accentText)
            Text(title).font(.system(size: 12)).foregroundColor(Socle.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.frame(minHeight: UI.rowHeight - 6).contentShape(Rectangle()).onTapGesture { isOn.toggle() }
    }
}

struct SField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(Socle.text)
            .padding(.horizontal, 10).frame(height: 26).background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SLink: View {
    let title: String
    let action: () -> Void
    var body: some View { Text(title).font(.system(size: 12)).foregroundColor(Socle.accentText).lineLimit(1).contentShape(Rectangle()).onTapGesture(perform: action) }
}

struct SStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var body: some View {
        HStack(spacing: 0) {
            cell("−") { value = max(range.lowerBound, value - step) }
            Text(String(format: step < 1 ? "%.1f" : "%.0f", value)).font(.system(size: 12).monospacedDigit()).foregroundColor(Socle.text).frame(width: 48)
            cell("+") { value = min(range.upperBound, value + step) }
        }.frame(height: 26).background(Socle.control, in: RoundedRectangle(cornerRadius: 4))
    }
    private func cell(_ t: String, _ a: @escaping () -> Void) -> some View {
        Text(t).font(.system(size: 13)).foregroundColor(Socle.text).frame(width: 28, height: 26).contentShape(Rectangle()).onTapGesture(perform: a)
    }
}

/// Section repliable (chevron + titre), comme dans le panneau de réglages d'EditReady.
struct SSection<C: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(Socle.subtle).frame(width: 12)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Socle.textStrong).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(height: UI.rowHeight).contentShape(Rectangle()).onTapGesture { open.toggle() }
            if open { content().padding(.leading, 20) }
        }
    }
}
