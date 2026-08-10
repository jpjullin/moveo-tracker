import Darwin
import Foundation

final class ProcessMetricsSampler {
    private struct Sample {
        var wallTime: TimeInterval
        var cpuTime: TimeInterval
        var residentMegabytes: Double
    }

    private var timer: DispatchSourceTimer?
    private var previous: Sample?

    func start(onMetrics: @escaping (_ cpuPercent: Double, _ residentMegabytes: Double) -> Void) {
        stop()
        previous = sample()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let current = self.sample(), let previous = self.previous else { return }
            self.previous = current
            let wallElapsed = current.wallTime - previous.wallTime
            guard wallElapsed > 0 else { return }
            let processCPUPercent = max(0, current.cpuTime - previous.cpuTime) / wallElapsed * 100
            onMetrics(processCPUPercent, current.residentMegabytes)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        previous = nil
    }

    private func sample() -> Sample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = TimeInterval(usage.ru_utime.tv_sec)
            + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec)
            + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        var taskInfo = mach_task_basic_info()
        var taskInfoCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let taskInfoResult = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &taskInfoCount
                )
            }
        }
        let residentMegabytes = taskInfoResult == KERN_SUCCESS
            ? Double(taskInfo.resident_size) / 1_048_576
            : 0
        return Sample(
            wallTime: ProcessInfo.processInfo.systemUptime,
            cpuTime: user + system,
            residentMegabytes: residentMegabytes
        )
    }
}
