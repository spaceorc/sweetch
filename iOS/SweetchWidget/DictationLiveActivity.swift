import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SweetchWidgets: WidgetBundle {
    var body: some Widget { DictationLiveActivity() }
}

/// What a dictation shows in the Dynamic Island and on the Lock Screen.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivity.self) { context in
            Row(state: context.state).padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { Row(state: context.state) }
            } compactLeading: {
                Image(systemName: phaseSymbol(context.state.phase)).foregroundStyle(phaseTint(context.state.phase))
            } compactTrailing: {
                Text(phaseCaption(context.state.phase)).font(.caption2)
            } minimal: {
                Image(systemName: phaseSymbol(context.state.phase)).foregroundStyle(phaseTint(context.state.phase))
            }
        }
    }

    struct Row: View {
        let state: DictationActivity.ContentState
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: phaseSymbol(state.phase)).foregroundStyle(phaseTint(state.phase))
                Text(state.text.isEmpty ? phaseCaption(state.phase) : state.text)
                    .font(.callout).lineLimit(4).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private func phaseSymbol(_ phase: DictationActivity.ContentState.Phase) -> String {
    switch phase {
    case .listening: "mic.fill"
    case .recognizing: "waveform"
    case .done: "checkmark"
    case .failed: "exclamationmark.triangle"
    case .warm: "mic"
    }
}

private func phaseTint(_ phase: DictationActivity.ContentState.Phase) -> Color {
    switch phase {
    case .listening: .red
    case .recognizing: .orange
    case .done: .green
    case .failed: .yellow
    case .warm: .secondary
    }
}

private func phaseCaption(_ phase: DictationActivity.ContentState.Phase) -> String {
    switch phase {
    case .listening: "listening…"
    case .recognizing: "recognizing…"
    case .done: "copied"
    case .failed: "failed"
    case .warm: "mic on — keyboard ready"
    }
}
