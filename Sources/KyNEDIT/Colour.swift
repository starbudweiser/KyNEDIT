import Foundation

/// Conversion log de caméra → Rec.709 : courbe inverse, changement de gamut (matrice calculée depuis les primaires), genou de hautes lumières, OETF Rec.709.
/// Résultat : un cube 3D 33³ appliqué en valeurs brutes (sans gestion de couleur) par le moteur de conversion.
enum Colour {
    typealias M = [Double]   // matrice 3×3 par lignes

    private static func mul(_ a: M, _ b: M) -> M {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return r
    }
    private static func inv(_ m: M) -> M {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [(e * i - f * h), (c * h - b * i), (b * f - c * e), (f * g - d * i), (a * i - c * g), (c * d - a * f), (d * h - e * g), (b * g - a * h), (a * e - b * d)].map { $0 / det }
    }
    /// RGB → XYZ à partir des primaires xy et du blanc.
    private static func rgbToXYZ(_ r: (Double, Double), _ g: (Double, Double), _ b: (Double, Double), white w: (Double, Double)) -> M {
        func xyz(_ p: (Double, Double)) -> [Double] { [p.0 / p.1, 1, (1 - p.0 - p.1) / p.1] }
        let cr = xyz(r), cg = xyz(g), cb = xyz(b), W = xyz(w)
        let P: M = [cr[0], cg[0], cb[0], cr[1], cg[1], cb[1], cr[2], cg[2], cb[2]]
        let Pi = inv(P)
        let s = [Pi[0] * W[0] + Pi[1] * W[1] + Pi[2] * W[2], Pi[3] * W[0] + Pi[4] * W[1] + Pi[5] * W[2], Pi[6] * W[0] + Pi[7] * W[1] + Pi[8] * W[2]]
        return [cr[0] * s[0], cg[0] * s[1], cb[0] * s[2], cr[1] * s[0], cg[1] * s[1], cb[1] * s[2], cr[2] * s[0], cg[2] * s[1], cb[2] * s[2]]
    }
    private static let d65 = (0.3127, 0.3290)
    private static let rec709 = rgbToXYZ((0.640, 0.330), (0.300, 0.600), (0.150, 0.060), white: d65)

    private static func gamut(_ cam: CamLog) -> M {
        let p: ((Double, Double), (Double, Double), (Double, Double))
        switch cam {
        case .logC3: p = ((0.6840, 0.3130), (0.2210, 0.8480), (0.0861, -0.1020))
        case .slog3Cine: p = ((0.766, 0.275), (0.225, 0.800), (0.089, -0.087))
        case .slog3: p = ((0.730, 0.280), (0.140, 0.855), (0.100, -0.050))
        case .vlog: p = ((0.730, 0.280), (0.165, 0.840), (0.100, -0.030))
        case .canonLog3: p = ((0.740, 0.270), (0.170, 1.140), (0.080, -0.100))
        case .bmdFilmGen5: p = ((0.7177215, 0.3171181), (0.2280410, 0.8615690), (0.1005841, -0.0820452))
        case .log3G10: p = ((0.780308, 0.304253), (0.121595, 1.493994), (0.095612, -0.084589))
        case .none: return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }
        return mul(inv(rec709), rgbToXYZ(p.0, p.1, p.2, white: d65))
    }

    /// Valeur encodée (0…1) → lumière linéaire de la scène.
    private static func linearize(_ cam: CamLog, _ v: Double) -> Double {
        switch cam {
        case .logC3:   // EI 800
            let cut = 0.010591, a = 5.555556, b = 0.052272, c = 0.247190, d = 0.385537, e = 5.367655, f = 0.092809
            return v > e * cut + f ? (pow(10, (v - d) / c) - b) / a : (v - f) / e
        case .slog3Cine, .slog3:
            return v >= 171.2102946929 / 1023 ? pow(10, (v * 1023 - 420) / 261.5) * 0.19 - 0.01 : (v * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
        case .vlog:
            return v < 0.181 ? (v - 0.125) / 5.6 : pow(10, (v - 0.598206) / 0.241514) - 0.00873
        case .canonLog3:
            if v < 0.04076162 { return -(pow(10, (0.12783901 - v) / 0.36726845) - 1) / 14.98325 }
            if v <= 0.105357102 { return (v - 0.0730597) / 2.3069815 }
            return (pow(10, (v - 0.12240537) / 0.36726845) - 1) / 14.98325
        case .bmdFilmGen5:
            let A = 0.08692876065491224, B = 0.005494072432257808, C = 0.5300133039660874, D = 8.283611957, E = 0.09246575342465753
            let logCut = D * 0.005 + E
            return v <= logCut ? (v - E) / D : exp((v - C) / A) - B
        case .log3G10:
            return (v >= 0 ? (pow(10, v / 0.224282) - 1) / 155.975327 : v / 15.1927) - 0.01
        case .none: return v
        }
    }

    private static func oetf709(_ x: Double) -> Double { x < 0.018 ? 4.5 * max(x, 0) : 1.099 * pow(x, 0.45) - 0.099 }
    /// Genou doux au-dessus de 0,8 : les hautes lumières se rapprochent de 1 sans écrêtage brutal.
    private static func knee(_ x: Double) -> Double { x <= 0.8 ? x : 0.8 + 0.2 * tanh((x - 0.8) / 0.2) }

    /// Cube RGBA 32 bits flottants, dimension `n`, ordre rouge le plus rapide (convention Core Image / .cube).
    static func cube(_ cam: CamLog, size n: Int = 33) -> Data {
        let m = gamut(cam)
        var out = [Float](); out.reserveCapacity(n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let lin = [r, g, b].map { linearize(cam, Double($0) / Double(n - 1)) }
            let rgb = (0..<3).map { i in knee(m[i * 3] * lin[0] + m[i * 3 + 1] * lin[1] + m[i * 3 + 2] * lin[2]) }
            out += [Float(min(max(oetf709(rgb[0]), 0), 1)), Float(min(max(oetf709(rgb[1]), 0), 1)), Float(min(max(oetf709(rgb[2]), 0), 1)), 1]
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
