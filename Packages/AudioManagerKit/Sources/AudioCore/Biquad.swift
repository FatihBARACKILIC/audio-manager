import Foundation

/// Coefficients of one normalised biquad section (a0 divided out).
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Float
    public var b1: Float
    public var b2: Float
    public var a1: Float
    public var a2: Float

    /// A section that passes the signal through untouched.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public var isIdentity: Bool {
        self == .identity
    }

    /// Magnitude of the section's frequency response, used by the tests to prove the
    /// filter actually does what the band promises.
    public func magnitude(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let cos2Omega = cos(2 * omega)
        let sinOmega = sin(omega)
        let sin2Omega = sin(2 * omega)

        let numeratorReal = Double(b0) + Double(b1) * cosOmega + Double(b2) * cos2Omega
        let numeratorImaginary = -(Double(b1) * sinOmega + Double(b2) * sin2Omega)
        let denominatorReal = 1 + Double(a1) * cosOmega + Double(a2) * cos2Omega
        let denominatorImaginary = -(Double(a1) * sinOmega + Double(a2) * sin2Omega)

        let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary).squareRoot()
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }
}

/// Peaking EQ section from the Audio EQ Cookbook (Robert Bristow-Johnson).
///
/// Each band of the graphic equalizer is one of these: a bell centred on the band
/// frequency that leaves the rest of the spectrum alone.
public enum PeakingEQ {
    /// Q chosen so ten octave-spaced bells overlap smoothly rather than leaving dips
    /// between them.
    public static let defaultQ: Double = 1.4

    public static func coefficients(
        frequency: Double,
        gainDecibels: Double,
        sampleRate: Double,
        q: Double = defaultQ
    ) -> BiquadCoefficients {
        // A band above Nyquist, a silly sample rate, or no gain at all: pass through.
        guard
            sampleRate > 0,
            frequency > 0,
            frequency < sampleRate / 2,
            q > 0,
            abs(gainDecibels) > 0.0001
        else { return .identity }

        let amplitude = pow(10, gainDecibels / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)

        let b0 = 1 + alpha * amplitude
        let b1 = -2 * cosOmega
        let b2 = 1 - alpha * amplitude
        let a0 = 1 + alpha / amplitude
        let a1 = -2 * cosOmega
        let a2 = 1 - alpha / amplitude

        guard a0 != 0, a0.isFinite else { return .identity }

        return BiquadCoefficients(
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
    }
}

/// Per-section filter memory, transposed direct form II (two state variables, good
/// numerical behaviour in single precision).
struct BiquadState {
    var z1: Float = 0
    var z2: Float = 0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
