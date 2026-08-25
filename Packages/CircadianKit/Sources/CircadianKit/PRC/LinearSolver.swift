import Foundation

/// Dense Gaussian elimination with partial pivoting.
///
/// The engine needs this exactly once: to solve the small linear system that fits a
/// dual-harmonic sinusoid to the published landmarks of a phase-response curve.
/// Keeping it here avoids pulling in Accelerate (which is unavailable on Linux and
/// overkill for a 4x4).
enum LinearSolver {

    /// Solves `A x = b`, returning `nil` if the matrix is singular to working precision.
    /// - Parameter matrix: row-major, `n` rows of `n` columns.
    static func solve(matrix: [[Double]], vector b: [Double]) -> [Double]? {
        let n = b.count
        guard matrix.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }

        var a = matrix
        var x = b

        for col in 0..<n {
            // Partial pivot: swap in the row with the largest magnitude in this column.
            var pivotRow = col
            var pivotMagnitude = abs(a[col][col])
            for row in (col + 1)..<n where abs(a[row][col]) > pivotMagnitude {
                pivotMagnitude = abs(a[row][col])
                pivotRow = row
            }
            guard pivotMagnitude > 1e-12 else { return nil }
            if pivotRow != col {
                a.swapAt(pivotRow, col)
                x.swapAt(pivotRow, col)
            }

            let pivot = a[col][col]
            for row in (col + 1)..<n {
                let factor = a[row][col] / pivot
                guard factor != 0 else { continue }
                for k in col..<n { a[row][k] -= factor * a[col][k] }
                x[row] -= factor * x[col]
            }
        }

        // Back-substitution.
        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = x[row]
            for k in (row + 1)..<n { sum -= a[row][k] * solution[k] }
            solution[row] = sum / a[row][row]
        }
        return solution
    }
}
