// Quaternion helpers — Hamilton convention, (w, x, y, z) stored as a
// plain struct so the field names read naturally.

import Foundation

struct Quat {
    var w, x, y, z: Double

    static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    func normalized() -> Quat {
        let n = (w*w + x*x + y*y + z*z).squareRoot()
        return n > 1e-12 ? Quat(w: w/n, x: x/n, y: y/n, z: z/n) : .identity
    }

    func conjugate() -> Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    static func * (lhs: Quat, rhs: Quat) -> Quat {
        Quat(
            w: lhs.w*rhs.w - lhs.x*rhs.x - lhs.y*rhs.y - lhs.z*rhs.z,
            x: lhs.w*rhs.x + lhs.x*rhs.w + lhs.y*rhs.z - lhs.z*rhs.y,
            y: lhs.w*rhs.y - lhs.x*rhs.z + lhs.y*rhs.w + lhs.z*rhs.x,
            z: lhs.w*rhs.z + lhs.x*rhs.y - lhs.y*rhs.x + lhs.z*rhs.w)
    }

    static func dot(_ a: Quat, _ b: Quat) -> Double {
        a.w*b.w + a.x*b.x + a.y*b.y + a.z*b.z
    }

    /// Normalized lerp. Faster than slerp and equivalent for the small
    /// frame-to-frame angles we see here.
    static func nlerp(_ a: Quat, _ b: Quat, _ t: Double) -> Quat {
        Quat(
            w: a.w * (1 - t) + b.w * t,
            x: a.x * (1 - t) + b.x * t,
            y: a.y * (1 - t) + b.y * t,
            z: a.z * (1 - t) + b.z * t).normalized()
    }

    static prefix func - (q: Quat) -> Quat {
        Quat(w: -q.w, x: -q.x, y: -q.y, z: -q.z)
    }

    /// 3×3 rotation matrix of a unit quaternion, row-major.
    var matrix: Matrix3 {
        let ww = w*w, xx = x*x, yy = y*y, zz = z*z
        let wx = w*x, wy = w*y, wz = w*z
        let xy = x*y, xz = x*z, yz = y*z
        _ = (ww, xx)  // silence unused warning if any
        return Matrix3(
            r0: (1 - 2*(yy + zz), 2*(xy - wz),     2*(xz + wy)),
            r1: (2*(xy + wz),     1 - 2*(xx + zz), 2*(yz - wx)),
            r2: (2*(xz - wy),     2*(yz + wx),     1 - 2*(xx + yy)))
    }
}

/// Minimal 3×3 matrix with row-major storage.
struct Matrix3 {
    var r0, r1, r2: (Double, Double, Double)

    subscript(_ i: Int, _ j: Int) -> Double {
        get {
            switch (i, j) {
            case (0, 0): return r0.0; case (0, 1): return r0.1; case (0, 2): return r0.2
            case (1, 0): return r1.0; case (1, 1): return r1.1; case (1, 2): return r1.2
            case (2, 0): return r2.0; case (2, 1): return r2.1; case (2, 2): return r2.2
            default: fatalError("Matrix3 index out of range")
            }
        }
        set {
            switch (i, j) {
            case (0, 0): r0.0 = newValue; case (0, 1): r0.1 = newValue; case (0, 2): r0.2 = newValue
            case (1, 0): r1.0 = newValue; case (1, 1): r1.1 = newValue; case (1, 2): r1.2 = newValue
            case (2, 0): r2.0 = newValue; case (2, 1): r2.1 = newValue; case (2, 2): r2.2 = newValue
            default: fatalError("Matrix3 index out of range")
            }
        }
    }

    /// Apply diag(s0, s1, s2) on both sides:  diag(s) * M * diag(s)
    /// Element (i, j) becomes s[i] * s[j] * M[i, j].
    func conjugatedByDiagonal(_ s: (Double, Double, Double)) -> Matrix3 {
        var out = self
        let sv = [s.0, s.1, s.2]
        for i in 0..<3 {
            for j in 0..<3 {
                out[i, j] = sv[i] * sv[j] * out[i, j]
            }
        }
        return out
    }

    /// Multiply Mᵀ by v (i.e. transpose-matrix times vector).
    func transposeTimes(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (r0.0*v.0 + r1.0*v.1 + r2.0*v.2,
         r0.1*v.0 + r1.1*v.1 + r2.1*v.2,
         r0.2*v.0 + r1.2*v.1 + r2.2*v.2)
    }

    /// Multiply self by a Z-rotation on the right:  M * Rz(angle)
    func timesRotZ(_ angle: Double) -> Matrix3 {
        let c = cos(angle), s = sin(angle)
        return Matrix3(
            r0: (r0.0*c + r0.1*s, -r0.0*s + r0.1*c, r0.2),
            r1: (r1.0*c + r1.1*s, -r1.0*s + r1.1*c, r1.2),
            r2: (r2.0*c + r2.1*s, -r2.0*s + r2.1*c, r2.2))
    }
}
