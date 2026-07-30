import SwiftUI

struct SectionTitle: View {
    let index: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(index)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(DropFramePalette.coral)
            Text(title)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(DropFramePalette.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(DropFramePalette.muted)
            }
        }
    }
}
