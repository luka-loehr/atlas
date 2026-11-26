import SwiftUI

/// Flat, quiet, Apple-native palette for the vector hardware stage.
/// Mirrors the restraint of bots.lukaloehr.com (flat neutral hardware, zero outlines,
/// one disciplined brand accent) while adapting cleanly to Light and Dark Mode.
private struct StagePalette {
    let dark: Bool

    var chassis: Color { dark ? Color(white: 0.18) : Color(white: 0.87) }
    var chassisInner: Color { dark ? Color(white: 0.115) : Color(white: 0.935) }
    var screen: Color { dark ? Color(white: 0.055) : Color(white: 0.13) }
    var stand: Color { dark ? Color(white: 0.145) : Color(white: 0.80) }
    var surface: Color { dark ? Color(white: 0.23) : Color(white: 0.22) }
    var tile: Color { dark ? Color(white: 0.16) : Color(white: 0.20) }
    var tileDetail: Color { dark ? Color(white: 0.24) : Color(white: 0.30) }
    var slot: Color { dark ? Color(white: 0.08) : Color(white: 0.78) }
    var track: Color { dark ? Color(white: 0.20) : Color(white: 0.84) }
    var desk: Color { dark ? Color(white: 0.14) : Color(white: 0.88) }
    var accent: Color { dark ? OnboardingContent.glacierCyan : OnboardingContent.oceanBlue }
    var accentSoft: Color { dark ? Color(red: 0.70, green: 0.94, blue: 0.97) : Color(red: 0.30, green: 0.74, blue: 0.90) }
}

/// The rotated concentric rounded-diamond emblem from Atlas's AppIcon.icon.
struct AtlasDiamondMark: View {
    var size: CGFloat = 24
    var tint: Color = OnboardingContent.oceanBlue

    var body: some View {
        Canvas { ctx, sz in
            let cx = sz.width / 2
            let cy = sz.height / 2
            let outer = sz.width * 0.54
            let inner = sz.width * 0.22

            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: .degrees(45))

            let outerRect = CGRect(x: -outer / 2, y: -outer / 2, width: outer, height: outer)
            ctx.fill(
                Path(roundedRect: outerRect, cornerRadius: outer * 0.18),
                with: .color(tint.opacity(0.28))
            )

            let innerRect = CGRect(x: -inner / 2, y: -inner / 2, width: inner, height: inner)
            ctx.fill(
                Path(roundedRect: innerRect, cornerRadius: inner * 0.22),
                with: .color(tint)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Procedural, 60fps vector illustration stage for the three onboarding scenes.
/// Respects Reduce Motion by freezing at each scene's clean resting frame.
struct OnboardingStageView: View {
    let scene: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 1.4 : timeline.date.timeIntervalSinceReferenceDate
            let palette = StagePalette(dark: colorScheme == .dark)

            Canvas { ctx, size in
                switch scene {
                case 0:
                    drawHomeServerScene(ctx: &ctx, size: size, t: t, p: palette)
                case 1:
                    drawLocalSearchScene(ctx: &ctx, size: size, t: t, p: palette)
                default:
                    drawTailscaleScene(ctx: &ctx, size: size, t: t, p: palette)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Scene 0: Home Server & Private Library

    private func drawHomeServerScene(ctx: inout GraphicsContext, size: CGSize, t: Double, p: StagePalette) {
        let cx = size.width / 2
        let cy = size.height * 0.56
        let unit = min(size.width / 320, size.height / 220)

        // Quiet ground line (like bots.lukaloehr.com's flat desk)
        let deskW = 244 * unit
        let deskH = 6 * unit
        let deskY = cy + 62 * unit
        fillRect(&ctx, CGRect(x: cx - deskW / 2, y: deskY, width: deskW, height: deskH), r: deskH / 2, color: p.desk)

        // Subtle floating photo cards gliding into the server top
        let cardCycle = 3.6
        for i in 0..<3 {
            let phase = ((t + Double(i) * (cardCycle / 3.0)).truncatingRemainder(dividingBy: cardCycle)) / cardCycle
            let ease = easeInOutCubic(phase)
            let xOff = CGFloat(i - 1) * 44 * unit * (1 - ease * 0.65)
            let startY = cy - 92 * unit
            let endY = cy - 34 * unit
            let y = startY + (endY - startY) * ease
            let alpha: Double = phase < 0.18
                ? phase / 0.18
                : (phase > 0.72 ? max(0, 1 - (phase - 0.72) / 0.28) : 1)
            let cardW = 30 * unit
            let cardH = 22 * unit
            let angle = Angle.degrees(Double(i - 1) * 7.0 * (1 - ease))

            ctx.drawLayer { layer in
                layer.opacity = alpha * 0.92
                layer.translateBy(x: cx + xOff, y: y)
                layer.rotate(by: angle)
                let rect = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
                fillRect(&layer, rect, r: 4.5 * unit, color: p.chassis)
                let inner = rect.insetBy(dx: 2.5 * unit, dy: 2.5 * unit)
                fillRect(&layer, inner, r: 2.5 * unit, color: p.screen)
                // Minimal horizon glyph inside each photo tile
                let hill = CGRect(x: inner.minX + 3 * unit, y: inner.maxY - 6 * unit, width: inner.width - 6 * unit, height: 3.5 * unit)
                fillRect(&layer, hill, r: 1.5 * unit, color: i == 1 ? p.accent.opacity(0.85) : p.tileDetail)
                let dot = CGRect(x: inner.maxX - 7 * unit, y: inner.minY + 3 * unit, width: 3.5 * unit, height: 3.5 * unit)
                layer.fill(Path(ellipseIn: dot), with: .color(i == 1 ? p.accentSoft : p.tileDetail))
            }
        }

        // Main home server chassis (clean matte enclosure)
        let srvW = 166 * unit
        let srvH = 104 * unit
        let srvRect = CGRect(x: cx - srvW / 2, y: deskY - srvH - 2 * unit, width: srvW, height: srvH)
        // Little rubber feet
        fillRect(&ctx, CGRect(x: srvRect.minX + 18 * unit, y: deskY - 4 * unit, width: 18 * unit, height: 4 * unit), r: 2 * unit, color: p.stand)
        fillRect(&ctx, CGRect(x: srvRect.maxX - 36 * unit, y: deskY - 4 * unit, width: 18 * unit, height: 4 * unit), r: 2 * unit, color: p.stand)

        fillRect(&ctx, srvRect, r: 16 * unit, color: p.chassis)
        fillRect(&ctx, srvRect.insetBy(dx: 7 * unit, dy: 7 * unit), r: 11 * unit, color: p.chassisInner)

        // Left side: 3 horizontal drive bays with sequential calm LED pulses
        let bayX = srvRect.minX + 18 * unit
        let bayW = 84 * unit
        let bayH = 19 * unit
        let bayGap = 8 * unit
        let bayStartY = srvRect.minY + 17 * unit
        let activeBay = Int((t * 1.1).truncatingRemainder(dividingBy: 3.0))

        for row in 0..<3 {
            let y = bayStartY + CGFloat(row) * (bayH + bayGap)
            let bay = CGRect(x: bayX, y: y, width: bayW, height: bayH)
            fillRect(&ctx, bay, r: 5 * unit, color: p.slot)
            // Drive latch line
            fillRect(&ctx, CGRect(x: bay.minX + 7 * unit, y: bay.midY - 1.5 * unit, width: 42 * unit, height: 3 * unit), r: 1.5 * unit, color: p.chassis)
            // Status LED
            let pulse = row == activeBay ? (0.65 + 0.35 * sin(t * 5.0)) : 0.28
            let led = CGRect(x: bay.maxX - 11 * unit, y: bay.midY - 2.5 * unit, width: 5 * unit, height: 5 * unit)
            ctx.fill(Path(ellipseIn: led), with: .color(p.accent.opacity(pulse)))
        }

        // Right side: Atlas concentric diamond emblem (breathing calmly)
        let emblemX = srvRect.maxX - 34 * unit
        let emblemY = srvRect.midY
        let breath = 1.0 + 0.04 * sin(t * 2.1)

        ctx.drawLayer { layer in
            layer.translateBy(x: emblemX, y: emblemY)
            layer.scaleBy(x: breath, y: breath)
            layer.rotate(by: .degrees(45))

            let outer = 28 * unit
            fillRect(&layer, CGRect(x: -outer / 2, y: -outer / 2, width: outer, height: outer), r: 5.5 * unit, color: p.accent.opacity(0.24))
            let inner = 12 * unit
            fillRect(&layer, CGRect(x: -inner / 2, y: -inner / 2, width: inner, height: inner), r: 2.8 * unit, color: p.accent)
        }
    }

    // MARK: - Scene 1: Local GPU Semantic Search

    private func drawLocalSearchScene(ctx: inout GraphicsContext, size: CGSize, t: Double, p: StagePalette) {
        let cx = size.width / 2
        let cy = size.height * 0.52
        let unit = min(size.width / 320, size.height / 220)

        // Minimal flat monitor (inspired by bots.lukaloehr.com COMPUTERS.monitor)
        let monW = 224 * unit
        let monH = 144 * unit
        let monRect = CGRect(x: cx - monW / 2, y: cy - monH / 2 - 6 * unit, width: monW, height: monH)

        // Stand neck & foot
        fillRect(&ctx, CGRect(x: cx - 10 * unit, y: monRect.maxY - 2 * unit, width: 20 * unit, height: 19 * unit), r: 2 * unit, color: p.stand)
        fillRect(&ctx, CGRect(x: cx - 36 * unit, y: monRect.maxY + 14 * unit, width: 72 * unit, height: 6 * unit), r: 3 * unit, color: p.chassis)

        // Monitor bezel & screen
        fillRect(&ctx, monRect, r: 14 * unit, color: p.chassis)
        let scr = monRect.insetBy(dx: 8 * unit, dy: 8 * unit)
        fillRect(&ctx, scr, r: 8 * unit, color: p.screen)

        // Search bar at top of screen
        let barH = 22 * unit
        let bar = CGRect(x: scr.minX + 12 * unit, y: scr.minY + 11 * unit, width: scr.width - 24 * unit, height: barH)
        fillRect(&ctx, bar, r: barH / 2, color: p.surface)

        // Cycle between two search "queries" every 3.4 seconds
        let cycleLen = 3.4
        let raw = t.truncatingRemainder(dividingBy: cycleLen * 2)
        let queryIndex = raw < cycleLen ? 0 : 1
        let localT = raw.truncatingRemainder(dividingBy: cycleLen)

        // Typing bar progress (0..0.32s)
        let typeProgress = easeOutCubic(min(1, localT / 0.55))
        let queryWidth = (queryIndex == 0 ? 78.0 : 58.0) * unit * typeProgress

        // Magnifying lens dot
        let lens = CGRect(x: bar.minX + 9 * unit, y: bar.midY - 3.5 * unit, width: 7 * unit, height: 7 * unit)
        ctx.stroke(Path(ellipseIn: lens), with: .color(p.accent), lineWidth: 1.8 * unit)

        // Query text pill
        if queryWidth > 2 {
            fillRect(&ctx, CGRect(x: bar.minX + 22 * unit, y: bar.midY - 2.5 * unit, width: queryWidth, height: 5 * unit), r: 2.5 * unit, color: Color.white.opacity(0.82))
        }
        // Blinking cursor (just like bots.lukaloehr.com .cursor)
        let cursorOn = Int(t * 2.2) % 2 == 0
        if cursorOn {
            fillRect(&ctx, CGRect(x: bar.minX + 25 * unit + queryWidth, y: bar.midY - 5 * unit, width: 2 * unit, height: 10 * unit), r: 1 * unit, color: p.accent)
        }

        // 4 x 2 Photo grid
        let cols = 4
        let rows = 2
        let gap = 7 * unit
        let gridX = scr.minX + 12 * unit
        let gridY = bar.maxY + 10 * unit
        let gridW = scr.width - 24 * unit
        let gridH = scr.maxY - gridY - 11 * unit
        let cellW = (gridW - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let cellH = (gridH - CGFloat(rows - 1) * gap) / CGFloat(rows)

        let matches: Set<Int> = queryIndex == 0 ? [1, 4, 6] : [0, 2, 5]
        let matchReveal = easeOutCubic(clamp((localT - 0.55) / 0.45, 0, 1))
        let fadeOut = easeInOutCubic(clamp((localT - 2.85) / 0.45, 0, 1))
        let highlight = matchReveal * (1 - fadeOut)

        for idx in 0..<(cols * rows) {
            let col = idx % cols
            let row = idx / cols
            let isMatch = matches.contains(idx)
            let lift = isMatch ? (-2.5 * unit * highlight) : 0
            let cell = CGRect(
                x: gridX + CGFloat(col) * (cellW + gap),
                y: gridY + CGFloat(row) * (cellH + gap) + lift,
                width: cellW,
                height: cellH
            )

            let fillColor: Color = isMatch
                ? p.accent.opacity(0.22 + 0.68 * highlight)
                : p.tile.opacity(1.0 - 0.42 * highlight)

            fillRect(&ctx, cell, r: 6 * unit, color: fillColor)

            // Minimal geometric photo content inside each tile
            let glyphColor: Color = isMatch
                ? Color.white.opacity(0.35 + 0.55 * highlight)
                : p.tileDetail.opacity(1.0 - 0.45 * highlight)

            if idx % 3 == 0 {
                // Portrait silhouette
                let head = CGRect(x: cell.midX - 4 * unit, y: cell.minY + 7 * unit, width: 8 * unit, height: 8 * unit)
                ctx.fill(Path(ellipseIn: head), with: .color(glyphColor))
                let shoulders = CGRect(x: cell.midX - 9 * unit, y: cell.minY + 17 * unit, width: 18 * unit, height: 8 * unit)
                fillRect(&ctx, shoulders, r: 4 * unit, color: glyphColor)
            } else {
                // Landscape / horizon
                let sun = CGRect(x: cell.maxX - 11 * unit, y: cell.minY + 6 * unit, width: 5 * unit, height: 5 * unit)
                ctx.fill(Path(ellipseIn: sun), with: .color(glyphColor))
                let bar1 = CGRect(x: cell.minX + 6 * unit, y: cell.maxY - 10 * unit, width: cell.width - 12 * unit, height: 4.5 * unit)
                fillRect(&ctx, bar1, r: 2 * unit, color: glyphColor)
            }
        }
    }

    // MARK: - Scene 2: Private Over Tailscale

    private func drawTailscaleScene(ctx: inout GraphicsContext, size: CGSize, t: Double, p: StagePalette) {
        let cx = size.width / 2
        let cy = size.height * 0.53
        let unit = min(size.width / 320, size.height / 220)

        // Quiet ground line
        let deskW = 264 * unit
        let deskY = cy + 54 * unit
        fillRect(&ctx, CGRect(x: cx - deskW / 2, y: deskY, width: deskW, height: 6 * unit), r: 3 * unit, color: p.desk)

        // Left: compact home server tower
        let srvW = 54 * unit
        let srvH = 82 * unit
        let srv = CGRect(x: cx - 118 * unit, y: deskY - srvH - 2 * unit, width: srvW, height: srvH)
        fillRect(&ctx, srv, r: 10 * unit, color: p.chassis)
        fillRect(&ctx, srv.insetBy(dx: 5 * unit, dy: 5 * unit), r: 6.5 * unit, color: p.chassisInner)
        for row in 0..<3 {
            let y = srv.minY + 13 * unit + CGFloat(row) * 16 * unit
            fillRect(&ctx, CGRect(x: srv.minX + 10 * unit, y: y, width: srvW - 20 * unit, height: 10 * unit), r: 3 * unit, color: p.slot)
            let led = CGRect(x: srv.maxX - 16 * unit, y: y + 3 * unit, width: 4 * unit, height: 4 * unit)
            ctx.fill(Path(ellipseIn: led), with: .color(p.accent.opacity(row == 0 ? 0.95 : 0.45)))
        }

        // Right: Laptop + iPhone silhouette pair
        let lapW = 74 * unit
        let lapH = 48 * unit
        let lap = CGRect(x: cx + 44 * unit, y: deskY - lapH - 7 * unit, width: lapW, height: lapH)
        fillRect(&ctx, lap, r: 7 * unit, color: p.chassis)
        fillRect(&ctx, lap.insetBy(dx: 4.5 * unit, dy: 4.5 * unit), r: 3.5 * unit, color: p.screen)
        // Laptop base
        fillRect(&ctx, CGRect(x: lap.minX - 7 * unit, y: deskY - 7 * unit, width: lapW + 14 * unit, height: 5 * unit), r: 2.5 * unit, color: p.stand)
        // Subtle photo grid hint on laptop screen
        for c in 0..<3 {
            fillRect(&ctx, CGRect(x: lap.minX + 9 * unit + CGFloat(c) * 19 * unit, y: lap.minY + 11 * unit, width: 15 * unit, height: 12 * unit), r: 2.5 * unit, color: c == 1 ? p.accent.opacity(0.85) : p.tile)
            fillRect(&ctx, CGRect(x: lap.minX + 9 * unit + CGFloat(c) * 19 * unit, y: lap.minY + 26 * unit, width: 15 * unit, height: 11 * unit), r: 2.5 * unit, color: p.tile)
        }

        // iPhone standing in front-right of laptop
        let phW = 28 * unit
        let phH = 52 * unit
        let ph = CGRect(x: lap.maxX - 12 * unit, y: deskY - phH - 2 * unit, width: phW, height: phH)
        fillRect(&ctx, ph, r: 6.5 * unit, color: p.chassis)
        fillRect(&ctx, ph.insetBy(dx: 3 * unit, dy: 3 * unit), r: 4.5 * unit, color: p.screen)
        fillRect(&ctx, CGRect(x: ph.midX - 4 * unit, y: ph.minY + 5.5 * unit, width: 8 * unit, height: 2.2 * unit), r: 1.1 * unit, color: p.surface)
        fillRect(&ctx, CGRect(x: ph.minX + 5.5 * unit, y: ph.minY + 12 * unit, width: phW - 11 * unit, height: 15 * unit), r: 2.5 * unit, color: p.accent.opacity(0.8))
        fillRect(&ctx, CGRect(x: ph.minX + 5.5 * unit, y: ph.minY + 30 * unit, width: phW - 11 * unit, height: 13 * unit), r: 2.5 * unit, color: p.tile)

        // Private encrypted tunnel between server and devices
        let startX = srv.maxX + 8 * unit
        let endX = lap.minX - 10 * unit
        let trackY = cy + 6 * unit

        var trackPath = Path()
        trackPath.move(to: CGPoint(x: startX, y: trackY))
        trackPath.addLine(to: CGPoint(x: endX, y: trackY))
        ctx.stroke(trackPath, with: .color(p.track), style: StrokeStyle(lineWidth: 2.5 * unit, lineCap: .round, dash: [4 * unit, 6 * unit]))

        // Animated encrypted packets flowing smoothly through the tunnel
        let span = endX - startX
        for i in 0..<2 {
            let phase = ((t * 0.52 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1.0))
            let px = startX + span * CGFloat(phase)
            let edgeFade = min(phase * 5, (1 - phase) * 5, 1)
            let pw = 14 * unit
            let phDot = 4.5 * unit
            fillRect(&ctx, CGRect(x: px - pw / 2, y: trackY - phDot / 2, width: pw, height: phDot), r: phDot / 2, color: p.accent.opacity(0.9 * edgeFade))
        }

        // Center lock capsule
        let lockW = 30 * unit
        let lockH = 30 * unit
        let lockCenter = CGPoint(x: (startX + endX) / 2, y: trackY)
        let lockPulse = 1.0 + 0.045 * sin(t * 3.2)
        ctx.drawLayer { layer in
            layer.translateBy(x: lockCenter.x, y: lockCenter.y)
            layer.scaleBy(x: lockPulse, y: lockPulse)
            fillRect(&layer, CGRect(x: -lockW / 2, y: -lockH / 2, width: lockW, height: lockH), r: lockH / 2, color: p.chassis)
            // Lock shackle
            var shackle = Path()
            shackle.addArc(center: CGPoint(x: 0, y: -2.5 * unit), radius: 4 * unit, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            layer.stroke(shackle, with: .color(p.accent), style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round))
            // Lock body
            fillRect(&layer, CGRect(x: -5.5 * unit, y: -2 * unit, width: 11 * unit, height: 8.5 * unit), r: 2.2 * unit, color: p.accent)
        }
    }
}

/// Compact live connection visual for the Connect form (server <-> device).
struct ServerLinkGraphic: View {
    let connecting: Bool
    let hasError: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || !connecting)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let p = StagePalette(dark: colorScheme == .dark)

            Canvas { ctx, size in
                let cy = size.height / 2
                let cx = size.width / 2
                let leftX = cx - 72
                let rightX = cx + 72

                // Mini server on the left
                let srv = CGRect(x: leftX - 18, y: cy - 22, width: 36, height: 44)
                fillRect(&ctx, srv, r: 8, color: p.chassis)
                fillRect(&ctx, srv.insetBy(dx: 4, dy: 4), r: 5, color: p.chassisInner)
                for row in 0..<2 {
                    let y = srv.minY + 11 + CGFloat(row) * 13
                    fillRect(&ctx, CGRect(x: srv.minX + 8, y: y, width: 20, height: 7), r: 2.5, color: p.slot)
                    let ledColor: Color = hasError ? .orange : p.accent
                    ctx.fill(Path(ellipseIn: CGRect(x: srv.maxX - 12, y: y + 2, width: 3, height: 3)), with: .color(ledColor.opacity(connecting ? 1 : 0.7)))
                }

                // Mini device on the right
                let dev = CGRect(x: rightX - 14, y: cy - 20, width: 28, height: 40)
                fillRect(&ctx, dev, r: 7, color: p.chassis)
                fillRect(&ctx, dev.insetBy(dx: 3, dy: 3), r: 4.5, color: p.screen)
                fillRect(&ctx, CGRect(x: dev.minX + 6, y: dev.minY + 10, width: 16, height: 10), r: 2.5, color: p.accent.opacity(0.65))
                fillRect(&ctx, CGRect(x: dev.minX + 6, y: dev.minY + 23, width: 16, height: 9), r: 2.5, color: p.tile)

                // Connection track
                let startX = srv.maxX + 10
                let endX = dev.minX - 10
                var line = Path()
                line.move(to: CGPoint(x: startX, y: cy))
                line.addLine(to: CGPoint(x: endX, y: cy))
                ctx.stroke(line, with: .color(p.track), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))

                if connecting {
                    let phase = (t * 1.1).truncatingRemainder(dividingBy: 1.0)
                    let px = startX + (endX - startX) * CGFloat(phase)
                    fillRect(&ctx, CGRect(x: px - 8, y: cy - 2.5, width: 16, height: 5), r: 2.5, color: p.accent)
                } else if hasError {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10)), with: .color(.red))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)), with: .color(p.accent.opacity(0.85)))
                }
            }
        }
        .frame(height: 60)
        .accessibilityHidden(true)
    }
}

// MARK: - Helpers

private func fillRect(_ ctx: inout GraphicsContext, _ rect: CGRect, r: CGFloat, color: Color) {
    ctx.fill(Path(roundedRect: rect, cornerRadius: r, style: .continuous), with: .color(color))
}

private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}

private func easeOutCubic(_ t: Double) -> Double {
    1 - pow(1 - clamp(t, 0, 1), 3)
}

private func easeInOutCubic(_ t: Double) -> Double {
    let x = clamp(t, 0, 1)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
