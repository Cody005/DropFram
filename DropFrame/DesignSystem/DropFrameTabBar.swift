import SwiftUI

struct DropFrameTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.32)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .bold))
                            .symbolEffect(.bounce, value: selection == tab)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(selection == tab ? DropFramePalette.paper : DropFramePalette.ink.opacity(0.58))
                    .frame(maxWidth: .infinity)
                    .frame(height: 57)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 17)
                                .fill(DropFramePalette.ink)
                                .matchedGeometryEffect(id: "tab", in: selectionAnimation)
                        }
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(5)
        .dropFrameGlass(in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: DropFramePalette.night.opacity(0.12), radius: 24, y: 12)
    }
}
