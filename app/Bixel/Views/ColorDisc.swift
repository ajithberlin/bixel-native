// ColorDisc.swift
//
// Procreate-style color disc: a hue ring around a saturation/value square.

import SwiftUI

struct ColorDisc: View {
    @Binding var color: BixelColor
    @State private var hue: Double = 0
    @State private var sat: Double = 1
    @State private var val: Double = 1

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outerR = size / 2
            let ringW = outerR * 0.20
            let squareR = outerR - ringW - 6

            ZStack {
                // Hue ring.
                Circle()
                    .stroke(
                        AngularGradient(gradient: Gradient(colors: hueColors), center: .center),
                        lineWidth: ringW * 2
                    )
                    .frame(width: (outerR - ringW) * 2, height: (outerR - ringW) * 2)
                    .position(center)

                // Saturation/value square.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.white, hueColor]),
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .overlay(
                        LinearGradient(
                            gradient: Gradient(colors: [.clear, .black]),
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .frame(width: squareR * 2, height: squareR * 2)
                    .position(center)

                // Hue marker.
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 2))
                    .shadow(radius: 2)
                    .position(hueMarker(center: center, radius: outerR - ringW))

                // SV marker.
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 2))
                    .shadow(radius: 2)
                    .position(svMarker(center: center, radius: squareR))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        update(g.location, center: center, outerR: outerR, ringW: ringW, squareR: squareR)
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { syncFromColor() }
        .onChange(of: color) { _ in syncFromColor() }
    }

    private var hueColor: Color {
        let c = BixelColor(h: hue, s: 1, v: 1)
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    private var hueColors: [Color] {
        (0..<13).map { i in
            let c = BixelColor(h: Double(i * 30), s: 1, v: 1)
            return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }
    }

    private func hueMarker(center: CGPoint, radius: CGFloat) -> CGPoint {
        let rad = hue * .pi / 180
        return CGPoint(x: center.x + cos(rad) * radius, y: center.y - sin(rad) * radius)
    }

    private func svMarker(center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(sat * 2 - 1) * radius,
            y: center.y + CGFloat(1 - val * 2) * radius
        )
    }

    private func update(_ location: CGPoint, center: CGPoint, outerR: CGFloat, ringW: CGFloat, squareR: CGFloat) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        let innerR = outerR - ringW * 2

        if dist >= innerR && dist <= outerR {
            // Ring region -> hue.
            var angle = atan2(-dy, dx) * 180 / .pi
            if angle < 0 { angle += 360 }
            hue = angle
        } else if abs(dx) <= squareR && abs(dy) <= squareR {
            // Square region -> saturation / value.
            sat = Double(min(max((dx / squareR + 1) / 2, 0), 1))
            val = Double(min(max((1 - dy / squareR) / 2, 0), 1))
        } else {
            return
        }
        commit()
    }

    private func commit() {
        color = BixelColor(h: hue, s: sat, v: val)
    }

    private func syncFromColor() {
        let hsv = color.hsv
        hue = hsv.h
        sat = hsv.s
        val = hsv.v
    }
}
