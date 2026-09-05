import SwiftUI

struct DetailView: View {
  @Binding var counter: Counter
  @State private var step: Int = 1

  var body: some View {
    VStack(spacing: 32) {
      Text("\(counter.count)")
        .font(.system(size: 80, weight: .bold))
        .foregroundStyle(counter.color)
        .contentTransition(.numericText())
        .animation(.spring(duration: 0.3), value: counter.count)

      HStack(spacing: 20) {
        Button {
          withAnimation {
            counter.count += step
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(counter.color, in: RoundedRectangle(cornerRadius: 14))
        }

        Button {
          withAnimation {
            counter.count -= step
          }
        } label: {
          Image(systemName: "minus")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(counter.color.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        }
      }

      HStack {
        Text("Step")
          .foregroundStyle(.secondary)
        Spacer()
        Stepper("\(step)", value: $step, in: 1...100)
          .fixedSize()
      }
      .padding(.horizontal, 32)

      Button("Reset Counter") {
        withAnimation {
          counter.count = 0
        }
      }
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(Color(red: 0.82, green: 0.45, blue: 0.35), in: RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 32)

      Spacer()
    }
    .padding(.top, 40)
    .navigationTitle(counter.name)
    .navigationBarTitleDisplayMode(.inline)
  }
}
