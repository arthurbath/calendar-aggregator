import SwiftUI

struct CalendarSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = SyncSettings()
    @State private var baseline = SyncSettings()
    @State private var message: String?
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Destination") {
                    Picker("Calendar", selection: $draft.destination) {
                        Text("Choose a Calendar").tag(CalendarReference?.none)
                        if let destination = draft.destination,
                           !model.choices.contains(where: { $0.writable && $0.reference == destination }) {
                            Text(destination.label).tag(Optional(destination))
                        }
                        ForEach(model.choices.filter(\.writable)) { choice in
                            Text(choiceLabel(choice)).tag(Optional(choice.reference))
                        }
                    }.disabled(!model.hasAccess)
                    Text("Changing the destination leaves existing events in the previous calendar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sources") {
                    if draft.sources.isEmpty {
                        Text("Add the calendars you want to combine.").foregroundStyle(.secondary)
                    }
                    ForEach(draft.sources.indices, id: \.self) { index in
                        sourceOptions(index)
                    }
                    Menu("Add Source Calendar") {
                        ForEach(availableSources) { choice in
                            Button(choiceLabel(choice)) { addSource(choice) }
                        }
                    }.disabled(availableSources.isEmpty)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !model.hasAccess {
                    Button("Allow Calendar Access", action: model.requestAccess)
                        .disabled(model.requestingAccess)
                }
                Spacer()
                Button("Cancel") { draft = baseline; message = nil }.disabled(draft == baseline)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(!model.hasAccess || draft == baseline || model.isSyncing)
            }.padding(12)
            if let message {
                Text(message)
                    .foregroundStyle(saveFailed ? Color.red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 12)
                    .accessibilityIdentifier("settings-message")
            }
        }
        .frame(minWidth: 490, minHeight: 400)
        .onAppear {
            model.refresh()
            baseline = model.settings
            draft = baseline
        }
    }

    private var availableSources: [CalendarChoice] {
        model.choices.filter { choice in
            !matches(draft.destination, choice) && !draft.sources.contains { matches($0.reference, choice) }
        }
    }

    private func matches(_ reference: CalendarReference?, _ choice: CalendarChoice) -> Bool {
        guard let reference else { return false }
        if let id = reference.identifier { return id == choice.id }
        return reference.title == choice.reference.title && reference.sourceTitle == choice.reference.sourceTitle
    }

    private func choiceLabel(_ choice: CalendarChoice) -> String {
        let label = choice.reference.label
        guard model.choices.filter({ $0.reference.label == label }).count > 1 else { return label }
        return "\(label) (\(choice.id.suffix(8)))"
    }

    private func sourceOptions(_ index: Int) -> some View {
        let source = draft.sources[index]
        let choice = model.choices.first { matches(source.reference, $0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(choice.map(choiceLabel) ?? source.reference.label).fontWeight(.semibold)
                if model.hasAccess && choice == nil {
                    Text("Unavailable").foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { draft.sources.remove(at: index) } label: {
                    Image(systemName: "minus.circle").accessibilityLabel("Remove \(source.reference.label)")
                }.buttonStyle(.borderless)
            }
            Toggle("Reveal Event Titles", isOn: Binding(
                get: { draft.sources[index].mode == .full },
                set: { draft.sources[index].mode = $0 ? .full : .busy }
            ))
            if source.mode == .busy {
                TextField("Replacement Title", text: Binding(
                    get: { draft.sources[index].replacementTitle ?? draft.busyEventTitle },
                    set: { draft.sources[index].replacementTitle = $0 }
                ))
            }
            Toggle("Include All-day Events", isOn: $draft.sources[index].includeAllDayEvents)
            if !source.excludedOrganizerEmails.isEmpty {
                Text("Keeps the organizer exclusions from your previous settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private func addSource(_ choice: CalendarChoice) {
        draft.sources.append(SourceSpec(title: choice.reference.title, sourceTitle: choice.reference.sourceTitle,
                                        mode: .full, includeAllDayEvents: true, excludedOrganizerEmails: [],
                                        identifier: choice.id))
    }

    private func save() {
        do {
            try model.save(draft)
            baseline = model.settings
            draft = baseline
            message = "Settings saved."
            saveFailed = false
        } catch {
            message = error.localizedDescription
            saveFailed = true
        }
    }
}
