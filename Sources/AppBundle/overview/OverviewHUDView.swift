import AppKit
import SwiftUI
import Common

struct OverviewCellInfo: Identifiable {
    let id: String              // workspace name
    let workspaceName: String
    /// Cell rect relative to the HUD panel in SwiftUI coordinates (Y-down, origin at top-left).
    let hudFrame: CGRect
    let label: String
}

struct OverviewHUDView: View {
    let cells: [OverviewCellInfo]
    @ObservedObject var selection: SelectionState

    var body: some View {
        ZStack {
            Color.clear

            ForEach(cells.indices, id: \.self) { idx in
                cellView(idx: idx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func cellView(idx: Int) -> some View {
        let cell = cells[idx]
        let isSelected = idx == selection.index

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.25),
                    lineWidth: isSelected ? 2.5 : 1
                )
                .frame(width: cell.hudFrame.width, height: cell.hudFrame.height)
                .allowsHitTesting(false)

            Text(cell.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.white.opacity(0.3) : Color.black.opacity(0.55))
                )
                .padding(.top, 6)
                .allowsHitTesting(false)
        }
        .frame(width: cell.hudFrame.width, height: cell.hudFrame.height)
        .position(x: cell.hudFrame.midX, y: cell.hudFrame.midY)
    }
}
