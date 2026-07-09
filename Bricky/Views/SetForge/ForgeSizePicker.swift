import SwiftUI

/// Shared size selector for both Set Forge flows. Larger sizes are a Bricky Pro
/// feature; locked rows show a lock and invoke `onLocked` (typically to present
/// the paywall).
struct ForgeSizePicker: View {
    @Binding var selected: VoxelModel.Size
    let isUnlocked: (VoxelModel.Size) -> Bool
    let onLocked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Size")
                .font(.headline)
            ForEach(VoxelModel.Size.allCases) { size in
                row(size)
            }
        }
    }

    private func row(_ size: VoxelModel.Size) -> some View {
        let unlocked = isUnlocked(size)
        let isSelected = selected == size
        return Button {
            if unlocked { selected = size } else { onLocked() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: size.iconName)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.legoBlue : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(size.rawValue).font(.subheadline.weight(isSelected ? .semibold : .regular))
                    Text(size.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !unlocked {
                    Image(systemName: "lock.fill").foregroundStyle(Color.legoOrange)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.legoBlue)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.legoBlue : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
