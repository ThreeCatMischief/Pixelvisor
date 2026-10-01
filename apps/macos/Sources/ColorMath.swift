// Color conversions for the panel: white temperature, hue/saturation, sRGB/linear.

import Foundation

enum ColorMath {
    /// Color of a black body at `kelvin` (Tanner Helland's fit, 1000-40000 K), as sRGB.
    static func kelvin(_ kelvin: Int) -> RGB {
        let t = Double(min(max(kelvin, 1000), 40000)) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        return RGB(clamp(r), clamp(g), clamp(b))
    }

    /// Fully bright color with `hue` and `saturation` in 0...1.
    static func color(hue: Double, saturation: Double) -> RGB {
        let (r, g, b) = hsvToRGB(h: hue, s: saturation, v: 1)
        return RGB(clamp(r * 255), clamp(g * 255), clamp(b * 255))
    }

    /// Hue and saturation of `c`, each 0...1.
    static func hueSaturation(_ c: RGB) -> (hue: Double, saturation: Double) {
        let (h, s, _) = rgbToHSV(r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255)
        return (h, s)
    }

    static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let h6 = (h - floor(h)) * 6
        let i = Int(h6) % 6
        let f = h6 - floor(h6)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    static func rgbToHSV(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        var h = 0.0
        if d > 0 {
            if maxC == r { h = (g - b) / d } else if maxC == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC > 0 ? d / maxC : 0, maxC)
    }

    /// sRGB transfer function, 0...1 both ways.
    static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func toSRGB(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func clamp(_ v: Double) -> Int { Int(min(max(v.rounded(), 0), 255)) }
}
