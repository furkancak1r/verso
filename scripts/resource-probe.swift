import CoreGraphics
import Darwin
import Foundation
import QuartzCore

@main
struct ResourceProbe {
    private static let width = 3840
    private static let height = 2160
    private static let warmupCycles = 3
    private static let measuredCycles = 60

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        precondition(status == KERN_SUCCESS)
        return UInt64(info.resident_size)
    }

    @MainActor
    private static func cycle(
        _ resource: TemporaryCaptureResource,
        _ layer: CALayer
    ) -> UInt64 {
        var attachedPeak: UInt64 = 0
        autoreleasepool {
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(
                CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
            )
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            resource.attach(image, to: layer)
            precondition(resource.image != nil && layer.contents != nil)
            attachedPeak = residentBytes()

            resource.clear()
            resource.clear()
            precondition(resource.image == nil && layer.contents == nil)
            CATransaction.commit()
        }
        CATransaction.flush()
        return attachedPeak
    }

    @MainActor
    static func main() {
        let resource = TemporaryCaptureResource()
        let layer = CALayer()
        layer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "contentsScale": NSNull()
        ]

        for _ in 0..<warmupCycles {
            _ = cycle(resource, layer)
        }
        Thread.sleep(forTimeInterval: 1)

        let baseline = residentBytes()
        var peak = baseline
        for _ in 0..<measuredCycles {
            peak = max(peak, cycle(resource, layer))
        }

        Thread.sleep(forTimeInterval: 1)
        let settled = residentBytes()
        precondition(resource.image == nil && layer.contents == nil)
        print(
            "{\"warmup_cycles\":\(warmupCycles)," +
            "\"cycle_count\":\(measuredCycles)," +
            "\"all_resources_cleared\":true," +
            "\"baseline_resident_bytes\":\(baseline)," +
            "\"settled_resident_bytes\":\(settled)," +
            "\"sampled_peak_resident_bytes\":\(peak)}"
        )
    }
}
