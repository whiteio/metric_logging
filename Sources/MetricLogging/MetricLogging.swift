import MetricKit
import Combine

public class MetricLogging: NSObject {
    var metricAttributes: AnyPublisher<[String: Double], Never> { return _metricAttributes.eraseToAnyPublisher() }

    private let _metricAttributes = PassthroughSubject<[String: Double], Never>()

    func start() {
        MXMetricManager.shared.add(self)
    }
}

protocol HandlesSliceMetricAttributes {
    func didReceiveMetricPayloads(_ payloads: [MXMetricPayload])
}

extension MetricLogging: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        guard let currentAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return
        }

        var attributes: [String: Double] = [:]

        if let averageTimeToFirstDraw = payloads.average(for: \.applicationLaunchMetrics, applicationVersion: currentAppVersion) {
            attributes["first_draw_avg"] = averageTimeToFirstDraw.value
        }
        if let averageHangTime = payloads.average(for: \.applicationResponsivenessMetrics, applicationVersion: currentAppVersion) {
            attributes["hang_time_avg"] = averageHangTime.value
        }

        guard !attributes.isEmpty else { return }

        _metricAttributes.send(attributes)
    }
}

protocol HistogrammedTimeMetric {
    var histogram: MXHistogram<UnitDuration> { get }
    var average: Measurement<UnitDuration> { get }
}

extension HistogrammedTimeMetric {
    /// Calculates the average duration in milliseconds for the given histogram values.
    var average: Measurement<UnitDuration> {
        let buckets = histogram.bucketEnumerator.compactMap { $0 as? MXHistogramBucket }
        let totalBucketsCount = buckets.reduce(0) { totalCount, bucket in
            var totalCount = totalCount
            totalCount += bucket.bucketCount
            return totalCount
        }
        let totalDurations: Double = buckets.reduce(0) { totalDuration, bucket in
            var totalDuration = totalDuration
            totalDuration += Double(bucket.bucketCount) * bucket.bucketEnd.value
            return totalDuration
        }
        let average = totalDurations / Double(totalBucketsCount)
        return Measurement(value: average, unit: UnitDuration.milliseconds)
    }
}

extension MXAppLaunchMetric: HistogrammedTimeMetric {
    var histogram: MXHistogram<UnitDuration> {
        histogrammedTimeToFirstDraw
    }
}

extension MXAppResponsivenessMetric: HistogrammedTimeMetric {
    var histogram: MXHistogram<UnitDuration> {
        histogrammedApplicationHangTime
    }
}

extension Array where Element == MXMetricPayload {

    /// Calculates the average Metric value for all payloads containing the given key path for the given application version.
    func average<Value: HistogrammedTimeMetric>(for keyPath: KeyPath<MXMetricPayload, Value?>, applicationVersion: String) -> Measurement<UnitDuration>? {
        let averages = filter(for: applicationVersion)
            .compactMap { payload in
                payload[keyPath: keyPath]?.average.value
            }

        guard !averages.isEmpty else { return nil }

        let average: Double = averages.reduce(0.0, +) / Double(averages.count)
        guard !average.isNaN else { return nil }

        return Measurement(value: average, unit: UnitDuration.milliseconds)
    }

    private func filter(for applicationVersion: String) -> [MXMetricPayload] {
        filter { payload in
            guard !payload.includesMultipleApplicationVersions else {
                // We only want to use payloads for the latest app version
                return false
            }
            return payload.latestApplicationVersion == applicationVersion
        }
    }
}
