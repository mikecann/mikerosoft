import SwiftUI

/// Shown while no phone is plugged in.
struct WaitingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Plug in an iPhone or iPad")
                .font(.title3.weight(.semibold))
            Text("Use a USB cable, unlock it, and tap Trust if it asks.\nEach phone opens in its own window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 380, height: 240)
    }
}
