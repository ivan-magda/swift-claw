import SwiftUI

struct Counter: Identifiable {
  let id = UUID()
  var name: String
  var count: Int
  var color: Color
}
struct ContentView: View {
  @State private var counters: [Counter] = [
    Counter(name: "Workouts", count: 28, color: Color(red: 0.47, green: 0.60, blue: 0.47)),
    Counter(name: "Projects", count: 14, color: Color(red: 0.42, green: 0.65, blue: 0.72)),
    Counter(name: "Ideas", count: 14, color: Color(red: 0.35, green: 0.58, blue: 0.62)),
  ]

  var body: some View {
    NavigationStack {
      List {
        ForEach($counters) { $counter in
          NavigationLink(destination: DetailView(counter: $counter)) {
            CounterRow(counter: counter)
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .navigationTitle("PulseCount")
    }
  }
}

struct CounterRow: View {
  let counter: Counter

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      VStack(alignment: .leading, spacing: 2) {
        Text(counter.name)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white.opacity(0.85))
        Text("\(counter.count)")
          .font(.system(size: 38, weight: .bold))
          .foregroundStyle(.white)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .background(counter.color, in: RoundedRectangle(cornerRadius: 12))

      Text("+1")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Circle().fill(.black.opacity(0.25)))
        .padding(12)
    }
  }
}
