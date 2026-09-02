import SwiftUI

struct GeneratedPreview: View {
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "wand.and.stars")
        .font(.system(size: 48))
        .foregroundStyle(.purple)
      Text("Generated screen")
        .font(.title.bold())
      Text("The app entry point came from a fixed harness.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
    .padding()
  }
}
