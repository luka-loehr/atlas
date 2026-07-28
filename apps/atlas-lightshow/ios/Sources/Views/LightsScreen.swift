import SwiftUI

/// Manual light board: every fixture directly steuerbar — ohne Show.
struct LightsScreen: View {
    var host: String
    var token: String
    @State private var model = LightsModel()

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 16) {
                        statusRow

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(LightsModel.lamps) { lamp in
                                LampCard(model: model, lamp: lamp)
                            }
                        }

                        SectionLabel(text: "Effekte")
                        HStack(spacing: 12) {
                            EffectCard(
                                title: "Laser", icon: "rays", tint: Theme.violet,
                                isOn: Binding(get: { model.laser }, set: { model.laser = $0; model.push() })
                            )
                            EffectCard(
                                title: "Strobe", icon: "bolt.fill", tint: Theme.warn,
                                isOn: Binding(get: { model.strobe }, set: { model.strobe = $0; model.push() })
                            )
                        }

                        FogHoldButton(client: model.client)
                            .padding(.top, 14)
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.sync() }
            }
            .navigationTitle("Lichter")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.allOff()
                    } label: {
                        Image(systemName: "power")
                    }
                    .tint(Theme.hot)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { model.allOn() }
                    } label: {
                        Image(systemName: "lightbulb.max.fill")
                    }
                }
            }
        }
        .task {
            model.host = host
            model.token = token
            await model.sync()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().tint(Theme.accent).scaleEffect(0.7)
                Text("Bridge startet — erster Befehl braucht ~4s")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else if let e = model.error {
                Circle().fill(Theme.hot).frame(width: 8, height: 8)
                Text(e)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                Circle().fill(model.bridge ? Theme.good : Theme.warn).frame(width: 8, height: 8)
                Text(model.bridge ? "Bridge aktiv — Lichter reagieren sofort" : "Bridge aus — startet beim ersten Befehl")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .animation(.default, value: model.busy)
    }
}

/// One fixture: glowing swatch (tap = an/aus) + native ColorPicker.
struct LampCard: View {
    @Bindable var model: LightsModel
    var lamp: Lamp

    private var isOn: Bool { model.on[lamp.id] }
    private var color: Color { model.colors[lamp.id] }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    model.on[lamp.id].toggle()
                }
                model.push()
            } label: {
                ZStack {
                    Circle()
                        .fill(isOn ? color : Color.white.opacity(0.06))
                        .frame(width: 64, height: 64)
                        .shadow(color: isOn ? color.opacity(0.8) : .clear, radius: 18)
                        .overlay(
                            Circle().strokeBorder(.white.opacity(isOn ? 0.35 : 0.12), lineWidth: 1)
                        )
                    Image(systemName: lamp.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isOn ? .black.opacity(0.7) : .white.opacity(0.35))
                }
            }
            .buttonStyle(.plain)

            Text(lamp.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.5))
                .lineLimit(1)

            ColorPicker(
                "Farbe",
                selection: Binding(
                    get: { model.colors[lamp.id] },
                    set: { c in
                        model.colors[lamp.id] = c
                        if !model.on[lamp.id] { model.on[lamp.id] = true }
                        model.push()
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// Laser / strobe plug toggle.
struct EffectCard: View {
    var title: String
    var icon: String
    var tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { isOn.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? .black.opacity(0.75) : tint)
                    .frame(width: 44, height: 44)
                    .background(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.06)), in: .circle)
                    .shadow(color: isOn ? tint.opacity(0.7) : .clear, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(isOn ? "AN" : "aus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOn ? tint : .white.opacity(0.4))
                }
                Spacer()
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}
