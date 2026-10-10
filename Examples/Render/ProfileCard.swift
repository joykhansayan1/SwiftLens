// Render without an Xcode project:
//   swiftlens render Examples/Render/ProfileCard.swift --appearance light dark --dynamic-type large xxxLarge
//   swiftlens live Examples/Render/ProfileCard.swift          # hot-reloading interactive window

import SwiftUI

struct ProfileCard: View {
    var name: String
    var role: String
    var isOnline: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay(Text(String(name.prefix(1))).font(.title2.bold()).foregroundStyle(.white))
                Circle()
                    .fill(isOnline ? Color.green : Color.gray)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(role).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 300)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .padding(20)
    }
}

#Preview("Online", traits: .sizeThatFitsLayout) {
    ProfileCard(name: "Taylor Swift-ish", role: "iOS Engineer", isOnline: true)
}

#Preview("Interactive") {
    @Previewable @State var online = false
    VStack {
        ProfileCard(name: "Alex", role: "Designer", isOnline: online)
        Toggle("Online", isOn: $online).padding(.horizontal, 24)
    }
    .padding(.bottom, 16)
}
