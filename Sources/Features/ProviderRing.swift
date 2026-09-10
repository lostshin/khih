import SwiftUI

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
///
/// When that provider is doing something right now, a second, much thinner arc
/// appears *inside* the ring, in the gap between the glyph and the track. It is
/// deliberately a different radius, a different weight and a neutral colour, so
/// it reads as a separate fact rather than as the usage number moving.
struct ProviderRing: View {
    /// Nil when the provider reports what is left but never says out of what —
    /// there is no arc to draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    let glyph: ProviderGlyph
    var isStale: Bool = false
    /// Blocked right now. Shown as spent whatever the arc says, because that is
    /// what it means for you — a ring reading 16% while the account is paused
    /// is technically true and practically a lie.
    var isBlocked: Bool = false
    var activity: ActivitySummary?
    /// A fetch this cell asked for, in flight.
    var isRefreshing: Bool = false
    var localPerformance: LocalModelPerformance?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.codenotchAccentColor) private var accentColor
    @State private var spin: Double = 0

    private var band: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: usedFraction ?? 0)
    }
    /// The arc is what is *left*, not what is spent: a full ring is a full
    /// allowance, and it empties as the window is used. The band above still
    /// reads the used fraction, so the colour thresholds — and everything
    /// downstream of them — are unchanged by which way the arc runs.
    private var sweep: CGFloat {
        // Empty, not merely red: blocked is nothing left, and an arc still
        // three-quarters drawn contradicts the colour it is drawn in.
        guard !isBlocked else { return 0 }
        return 1 - CGFloat(min(max(usedFraction ?? 0, 0), 1))
    }

    var body: some View {
        ZStack {
            // Dimming applies to the usage reading only. Whether Claude is
            // working right now is known first-hand and stays at full strength
            // even when the percentage behind it has gone stale.
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)

                if let localPerformance {
                    Circle()
                        .strokeBorder(localPerformance.band.color, lineWidth: NotchLayout.progressStroke)
                        .animation(NotchMotion.reading, value: localPerformance.band)
                } else if usedFraction != nil {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: sweep)
                        .stroke(
                            band.color(accent: accentColor),
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        // Reading changes must not retime a refresh already in flight.
                        .animation(reduceMotion ? nil : NotchMotion.reading, value: sweep)
                        .animation(reduceMotion ? nil : NotchMotion.reading, value: band)
                        .animation(reduceMotion ? nil : NotchMotion.refreshTurn) { content in
                            content.rotationEffect(.degrees(reduceMotion ? -90 : -90 + spin))
                        }
                }

                ProviderGlyphView(glyph: glyph)
                    .foregroundStyle(Palette.textPrimary)
                    // A spent limit dims its glyph so the ring reads as "waiting".
                    // Under reduce-transparency, boost opacity so it stays legible without low alpha.
                    .opacity(band == .exhausted ? (reduceTransparency ? 0.7 : 0.35) : 1)
            }
            .opacity(isStale ? (reduceTransparency ? 0.75 : 0.45) : 1)

            // Keep the arc mounted: inserting it at the destination angle loses
            // the first turn. Opacity and rotation have separate transactions.
            Circle()
                .inset(by: NotchLayout.trackStroke / 2)
                .trim(from: 0, to: 0.22)
                .stroke(Palette.textPrimary, style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round))
                .animation(NotchMotion.crossfade) { content in
                    content.opacity(isRefreshing ? 1 : 0)
                }
                .animation(reduceMotion ? nil : NotchMotion.refreshTurn) { content in
                    content.rotationEffect(.degrees(reduceMotion ? -90 : -90 + spin))
                }
                .accessibilityHidden(true)
            if let activity, activity.state != .idle {
                ActivityArc(summary: activity)
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        // Pressed in while it works, and released when the answer lands. The
        // ring is the button, so the ring is what should feel pressed.
        .animation(reduceMotion ? nil : NotchMotion.refreshPress) { content in
            content.scaleEffect(isRefreshing && !reduceMotion ? 0.93 : 1)
        }
        .onChange(of: isRefreshing, initial: true) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // A finite turn, isolated from reading and press animations. The
            // short arc fades out on completion without cutting the turn off.
            spin += 360
        }
    }
}

/// The inner indicator: a short arc that spins while work is happening, and a
/// full pulsing ring when something is blocked waiting on you.
private struct ActivityArc: View {
    let summary: ActivitySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @State private var spinning = false
    @State private var pulsing = false

    /// How much of the circle the moving arc covers.
    private let arcFraction: CGFloat = 0.25

    private var inset: CGFloat {
        (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2
    }

    var body: some View {
        Group {
            switch summary.state {
            case .working: spinner
            case .waiting: pulse
            case .idle:    EmptyView()
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }

    private var spinner: some View {
        Circle()
            .inset(by: inset)
            .trim(from: 0, to: arcFraction)
            .stroke(
                summary.color,
                style: StrokeStyle(lineWidth: NotchLayout.activityStroke, lineCap: .round)
            )
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
            .onDisappear { spinning = false }
    }

    private var pulse: some View {
        Circle()
            .inset(by: inset)
            .stroke(summary.color, lineWidth: NotchLayout.activityStroke)
            .opacity(pulsing ? (reduceTransparency ? 0.65 : 0.3) : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
    }
}

struct ProviderCell: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    var isRefreshing: Bool = false

    /// A dash, not "0%": nothing read is not the same as nothing used.
    private var readingText: String {
        snapshot.hasReading ? snapshot.headlineText : "—"
    }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                usedFraction: snapshot.hasReading ? snapshot.ringFraction : nil,
                glyph: snapshot.glyph,
                isStale: snapshot.status.isStale || !snapshot.hasReading,
                isBlocked: snapshot.block != nil,
                activity: activity,
                isRefreshing: isRefreshing,
                localPerformance: snapshot.localPerformance
            )
            Text(readingText)
                .font(Typography.percent)
                .foregroundStyle(snapshot.showsLocalPerformance && snapshot.localPerformance == nil
                                 ? Palette.textSecondary : Palette.textPrimary)
                // Keep local speeds inside the ring's column so longer units
                // cannot consume the notch's existing side margins.
                .lineLimit(1)
                .minimumScaleFactor(snapshot.localModel == nil ? 1 : 0.5)
                .fixedSize(horizontal: snapshot.localModel == nil, vertical: false)
                .frame(width: snapshot.localModel == nil ? nil : NotchLayout.ringDiameter,
                       height: NotchLayout.percentLineHeight)
                .contentTransition(.numericText())
                .animation(NotchMotion.reading, value: readingText)
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.localModel.map {
            "\($0.brand.map { "\($0.displayName), " } ?? "")\($0.name), \(snapshot.displayName) local, \(snapshot.showsLocalPerformance ? (snapshot.localPerformance.map { "Last generation speed \($0.speedText), \($0.band.label)" } ?? "Speed not measured") : "Loaded"), \($0.detail)\(activity?.state == .working ? ", Thinking" : "")"
        } ?? "\(snapshot.displayName), \(readingText)")
    }
}
