import Foundation

extension Int {
    /// 指标数字：千位分隔，和原型一致。
    var compactMetric: String {
        formatted(.number)
    }
}

