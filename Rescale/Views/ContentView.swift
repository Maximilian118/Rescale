import SwiftUI

/// Main menu bar content — lists external monitors or shows an empty state.
struct ContentView: View {
    @EnvironmentObject var displayService: DisplayService

    /// Physical external monitors only — excludes built-in and virtual displays.
    private var externalMonitors: [Monitor] {
        displayService.monitors.filter {
            !$0.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if externalMonitors.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No external displays connected")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // One card per external monitor
                ForEach(Array(externalMonitors.enumerated()), id: \.element.id) { index, monitor in
                    if index > 0 {
                        Divider().padding(.horizontal, 12)
                    }
                    MonitorCardView(monitor: monitor)
                }
            }

            Divider().opacity(0.4)

            // Footer
            HStack {
                Text("Rescale v0.1.0")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
    }
}
