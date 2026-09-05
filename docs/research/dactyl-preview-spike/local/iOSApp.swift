import SwiftUI

struct SimulatorHabit: Identifiable {
  let id = UUID()
  let title: String
  let icon: String
  let progress: Double
}

struct SimulatorContentView: View {
  private let habits = [
    SimulatorHabit(title: "Morning walk", icon: "figure.walk", progress: 0.72),
    SimulatorHabit(title: "Read 20 min", icon: "book.fill", progress: 0.48),
    SimulatorHabit(title: "Drink water", icon: "drop.fill", progress: 0.86),
  ]

  var body: some View {
    ZStack {
      Color(red: 0.95, green: 0.96, blue: 0.98)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 22) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Your habits")
              .font(.largeTitle.bold())
            Text("3 habits in progress")
              .foregroundStyle(.secondary)
          }

          Spacer()

          Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 42))
            .foregroundStyle(.indigo)
        }

        VStack(spacing: 12) {
          ForEach(habits) { habit in
            HStack(spacing: 14) {
              Image(systemName: habit.icon)
                .frame(width: 38, height: 38)
                .background(.indigo.opacity(0.12), in: Circle())
                .foregroundStyle(.indigo)

              VStack(alignment: .leading, spacing: 8) {
                Text(habit.title)
                  .font(.headline)
                ProgressView(value: habit.progress)
                  .tint(.indigo)
              }
            }
            .padding(16)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
          }
        }

        Spacer()

        Button("Add a habit", systemImage: "plus") {}
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(.indigo, in: RoundedRectangle(cornerRadius: 16))
          .foregroundStyle(.white)
      }
      .padding(24)
    }
  }
}

@main
struct PreviewApp: App {
  var body: some Scene {
    WindowGroup {
      SimulatorContentView()
    }
  }
}
