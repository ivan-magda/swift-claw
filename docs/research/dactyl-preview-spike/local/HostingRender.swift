import AppKit
import SwiftUI

struct HostingPreview: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("NSHostingView")
        .font(.largeTitle.bold())

      HStack(spacing: 14) {
        Image(systemName: "figure.walk")
          .foregroundStyle(.indigo)
        VStack(alignment: .leading, spacing: 8) {
          Text("Morning walk")
            .font(.headline)
          ProgressView(value: 0.72)
            .tint(.indigo)
        }
      }
      .padding(16)
      .background(.white, in: RoundedRectangle(cornerRadius: 18))
    }
    .padding(24)
    .frame(width: 393, height: 300, alignment: .topLeading)
    .background(Color(red: 0.95, green: 0.96, blue: 0.98))
  }
}

@main
struct HostingRenderCommand {
  @MainActor
  static func main() throws {
    let output = CommandLine.arguments.dropFirst().first ?? "hosting.png"
    let hostingView = NSHostingView(rootView: HostingPreview())
    hostingView.frame = NSRect(x: 0, y: 0, width: 393, height: 300)
    hostingView.appearance = NSAppearance(named: .aqua)
    hostingView.layoutSubtreeIfNeeded()

    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }

    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }

    try png.write(to: URL(fileURLWithPath: output), options: .atomic)
    print("wrote \(output), \(png.count) bytes")
  }
}
