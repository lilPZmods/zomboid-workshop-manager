// Daily Workshop stats per item, recorded on every Steam check.
// Field names match the Steam Web API (and the lilPZmods modstats dashboard),
// so history.json files from that tool can be dropped in.

import Charts
import Foundation
import SwiftUI

struct Snapshot: Codable, Identifiable {
  var date: String            // yyyy-MM-dd, local time
  var values: [String: Int]
  var id: String { date }
  var day: Date { Snapshot.parser.date(from: date) ?? .distantPast }

  static let parser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()
}

enum Metric: String, CaseIterable, Identifiable {
  case subs, life_subs, views, favs
  var id: String { rawValue }
  var label: String {
    switch self {
    case .subs: return "Subscribers"
    case .life_subs: return "Lifetime subs"
    case .views: return "Views"
    case .favs: return "Favorites"
    }
  }
}

/// workshop id -> snapshots, oldest first. Stored in Application Support/history.json.
final class StatsHistory {
  private let file: URL
  private(set) var all: [String: [Snapshot]] = [:]

  init(directory: URL) {
    file = directory.appendingPathComponent("history.json")
    if let d = try? Data(contentsOf: file), let h = try? JSONDecoder().decode([String: [Snapshot]].self, from: d) {
      all = h.mapValues { $0.sorted { $0.date < $1.date } }
    }
  }

  func snapshots(_ id: String) -> [Snapshot] { all[id] ?? [] }

  /// Keeps one snapshot per day: today's is replaced by the latest numbers.
  func record(_ stats: [String: [String: UInt64]]) {
    let today = Snapshot.parser.string(from: Date())
    for (id, values) in stats where !values.isEmpty {
      var list = all[id] ?? []
      let snap = Snapshot(date: today, values: values.mapValues { Int($0) })
      // Also drops entries dated after today, e.g. from a tool that dates snapshots in UTC.
      list.removeAll { $0.date >= today }
      list.append(snap)
      all[id] = list
    }
    if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
  }
}

let statGreen = Color(red: 0x8d / 255, green: 0xb5 / 255, blue: 0x54 / 255)

/// Number tiles plus a line chart for one item.
struct StatsBox: View {
  var snapshots: [Snapshot]
  @AppStorage("statsMetric") private var metric: Metric = .subs
  @State private var hover: Snapshot?

  var body: some View {
    GroupBox {
      if let last = snapshots.last {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            tile("Subscribers", "subs", last)
            tile("Lifetime subs", "life_subs", last)
            tile("Views", "views", last)
            tile("Favorites", "favs", last)
            tile("Comments", "comments", last)
            VStack(alignment: .leading, spacing: 2) {
              Text("Votes").font(.caption).foregroundStyle(.secondary)
              Text("\(last.values["up"] ?? 0) ▲  \(last.values["down"] ?? 0) ▼").font(.title3.monospacedDigit().bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          Picker("", selection: $metric) {
            ForEach(Metric.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
          chart
          if snapshots.count == 1 {
            Text("Tracking started \(last.date). The graph gains a point every day the app checks Steam.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(6)
      } else {
        Text("No stats yet. They are recorded each time the app checks Steam.").foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(6)
      }
    } label: {
      Label("Stats", systemImage: "chart.xyaxis.line")
    }
  }

  func value(_ s: Snapshot) -> Int { s.values[metric.rawValue] ?? 0 }

  func change(_ key: String, days: Int) -> Int? {
    guard let last = snapshots.last, let lastDay = Calendar.current.date(byAdding: .day, value: -days, to: last.day) else { return nil }
    guard let then = snapshots.last(where: { $0.day <= lastDay }) else { return nil }
    return (last.values[key] ?? 0) - (then.values[key] ?? 0)
  }

  func tile(_ label: String, _ key: String, _ last: Snapshot) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text((last.values[key] ?? 0).formatted()).font(.title3.monospacedDigit().bold())
      HStack(spacing: 4) {
        chip(change(key, days: 1), "day")
        chip(change(key, days: 7), "7d")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder func chip(_ d: Int?, _ span: String) -> some View {
    if let d, d != 0 {
      Text("\(d > 0 ? "+" : "")\(d) \(span)").font(.caption2.monospacedDigit())
        .foregroundStyle(d > 0 ? statGreen : .red)
    } else if d != nil {
      Text("0 \(span)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
    }
  }

  var chart: some View {
    Chart {
      ForEach(snapshots) { s in
        AreaMark(x: .value("Day", s.day), y: .value(metric.label, value(s)))
          .foregroundStyle(statGreen.opacity(0.14))
        LineMark(x: .value("Day", s.day), y: .value(metric.label, value(s)))
          .foregroundStyle(statGreen).lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
      }
      if let last = snapshots.last {
        PointMark(x: .value("Day", last.day), y: .value(metric.label, value(last)))
          .foregroundStyle(statGreen).symbolSize(50)
          .annotation(position: .top, alignment: .trailing) {
            Text(value(last).formatted()).font(.caption.bold())
          }
      }
      if let h = hover {
        RuleMark(x: .value("Day", h.day)).foregroundStyle(.secondary.opacity(0.5))
        PointMark(x: .value("Day", h.day), y: .value(metric.label, value(h))).foregroundStyle(statGreen)
          .annotation(position: .top) {
            Text("\(h.day.formatted(.dateTime.month(.abbreviated).day())): \(value(h).formatted())")
              .font(.caption).padding(4).background(.background, in: RoundedRectangle(cornerRadius: 4))
          }
      }
    }
    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
    .chartYScale(domain: .automatic(includesZero: true))
    .chartOverlay { proxy in
      GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let p):
              guard let plot = proxy.plotFrame, let date: Date = proxy.value(atX: p.x - geo[plot].origin.x) else { return }
              hover = snapshots.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
            case .ended:
              hover = nil
            }
          }
      }
    }
    .frame(height: 170)
  }
}

/// Tiny subscriber line for the project list.
struct Sparkline: View {
  var snapshots: [Snapshot]
  var body: some View {
    Chart(snapshots) { s in
      LineMark(x: .value("Day", s.day), y: .value("Subs", s.values["subs"] ?? 0))
        .foregroundStyle(statGreen).lineStyle(StrokeStyle(lineWidth: 1.5))
    }
    .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
    .chartYScale(domain: .automatic(includesZero: false))
    .frame(width: 44, height: 16)
  }
}
