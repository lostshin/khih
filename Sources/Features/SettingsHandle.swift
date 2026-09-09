import SwiftUI

/// The settings control, below the notch.
///
/// At rest it is a single arc — a segment of a circle's edge, tucked into the
/// corner the notch's bottom flare makes. On hover that same circle fills in and
/// takes a gear. The two states are the same circle, which is what makes the
/// change read as one object waking up rather than as one thing being swapped
/// for another.
///
/// It is a bare arc at rest because the notch is meant to be glanceable: a
/// permanently visible gear is a second thing competing with the readings, and
/// the readings are the point. An arc says "there is something here" without
/// asserting anything.
struct SettingsOrb: View {
    let isHovered: Bool
    var edge: NotchEdge = .right
    /// True when the arc traces the bar's own rounded corner from outside
    /// rather than a flare from inside — a flush bar has no flare to tuck into.
    var convex: Bool = false
    /// The circle the resting arc follows.
    var arcRadius: CGFloat = NotchLayout.orbArcRadius
    /// How far the arc sits from the button. Zero inside a flare's pocket,
    /// where the two are the same object; back onto the corner when the button
    /// has had to move clear of the bar.
    var arcOffset: CGSize = .zero
    /// How many times the gear has been asked to turn. See
    /// `NotchViewModel.settingsSpins`.
    var spins: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which quarter of the circle the resting arc occupies.
    ///
    /// The arc has to parallel the flare at the far end of the notch, so it
    /// faces two ways at once: **back along the stack**, toward the notch it
    /// hangs off, and **outward**, toward the bezel it is about to merge into.
    /// On the right edge that is twelve o'clock round to three, which is the
    /// arc this was drawn as before there was any choice of edge. Turn the
    /// notch and the same two directions pick a different quadrant.
    ///
    /// SwiftUI's `Circle` trim starts at three o'clock and runs clockwise, with
    /// y growing downward.
    /// Hugging a corner from outside is the same relationship as hugging a
    /// flare from inside, turned through half a circle.
    static func restingTrim(for edge: NotchEdge, convex: Bool) -> ClosedRange<CGFloat> {
        let concave = restingTrim(for: edge)
        guard convex else { return concave }
        let turned = (concave.lowerBound + 0.5).truncatingRemainder(dividingBy: 1)
        return turned...(turned + 0.25)
    }

    static func restingTrim(for edge: NotchEdge) -> ClosedRange<CGFloat> {
        switch edge {
        case .right:  return 0.75...1.0      // up, round to the right
        case .left:   return 0.5...0.75      // left, round to up
        case .top:    return 0.5...0.75      // left, round to up
        case .bottom: return 0.25...0.5      // down, round to the left
        }
    }

    private var restingTrim: ClosedRange<CGFloat> { Self.restingTrim(for: edge, convex: convex) }

    /// How far the button dips under a click.
    ///
    /// Shallow on purpose. This is a 22pt control tucked against the bezel, and
    /// a deeper press reads as the whole notch flinching rather than as one
    /// button being pushed.
    private static let squeezeScale: CGFloat = 0.84



    var body: some View {
        ZStack {
            // The resting arc, on a circle one gap inside the flare's own.
            Circle()
                .trim(from: restingTrim.lowerBound, to: restingTrim.upperBound)
                .stroke(
                    Palette.notch,
                    style: StrokeStyle(lineWidth: NotchLayout.orbStroke, lineCap: .round)
                )
                .frame(width: arcRadius * 2, height: arcRadius * 2)
                .opacity(isHovered ? 0 : 1)
                .scaleEffect(isHovered ? 0.86 : 1)
                .offset(arcOffset)

            Circle()
                .fill(Palette.notch)
                .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 1.1)

            Image(systemName: "gearshape")
                .font(.system(size: NotchLayout.orbGlyph, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)
                // Two rotations on one glyph: the wake-up from the hover
                // state, and a full turn per click. Summed rather than
                // applied separately so a click mid-hover does not fight the
                // -60 the gear is still arriving from.
                .rotationEffect(.degrees((isHovered ? 0 : -60) + Double(spins) * 360))
                .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.55,
                                                                      dampingFraction: 0.72),
                                                              reduceMotion),
                           value: spins)
        }
        // Sized to the larger of the two states, and never clipped: the arc
        // may sit well outside this frame when it has stayed back on the
        // corner the button hangs from.
        .frame(width: arcRadius * 2 + NotchLayout.orbStroke,
               height: arcRadius * 2 + NotchLayout.orbStroke)
        .animation(
            NotchMotion.respectingReduceMotion(
                .spring(response: 0.36, dampingFraction: 0.7), reduceMotion
            ),
            value: isHovered
        )
        // The press, on the same counter as the turn. A click reaches this
        // view as one event — the panel's own hit test and the SwiftUI
        // gesture both bump `spins`, and neither reports mouse-down and
        // mouse-up separately — so the dip and the release are keyframed off
        // that single tick rather than tracked from a press state that does
        // not exist here.
        //
        // Down fast and back slower: a press is sharp, a release settles.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: spins) { orb, scale in
            orb.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(reduceMotion ? 1 : Self.squeezeScale,
                           duration: 0.09, spring: .snappy)
            SpringKeyframe(1, duration: 0.34, spring: .bouncy)
        }
    }
}
