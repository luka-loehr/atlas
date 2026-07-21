import Foundation

/// Mirrors the JSON served by atlas-agent at /api/metrics.
struct Metrics: Codable, Sendable {
    let hostname: String
    let ts: Int
    let uptimeS: Int
    let load: [Double]
    let cpu: CPU
    let mem: Mem
    let gpu: GPU?
    let power: Power?
    let disk: Disk
    let net: Net?
    let containers: [Container]

    enum CodingKeys: String, CodingKey {
        case hostname, ts, load, cpu, mem, gpu, power, disk, net, containers
        case uptimeS = "uptime_s"
    }

    /// Full-system power estimate: measured CPU (RAPL) + GPU + baseline / PSU.
    struct Power: Codable, Sendable {
        let cpuW: Double?
        let gpuW: Double?
        let systemW: Double?
        enum CodingKeys: String, CodingKey {
            case cpuW = "cpu_w"
            case gpuW = "gpu_w"
            case systemW = "system_w"
        }
    }

    struct Net: Codable, Sendable {
        let rxBytes: UInt64
        let txBytes: UInt64
        enum CodingKeys: String, CodingKey {
            case rxBytes = "rx_bytes"
            case txBytes = "tx_bytes"
        }
    }

    struct CPU: Codable, Sendable {
        let usage: Double
        let cores: Int
        let tempC: Double?
        enum CodingKeys: String, CodingKey {
            case usage, cores
            case tempC = "temp_c"
        }
    }

    struct Mem: Codable, Sendable {
        let usedGb: Double
        let totalGb: Double
        let usage: Double
        enum CodingKeys: String, CodingKey {
            case usage
            case usedGb = "used_gb"
            case totalGb = "total_gb"
        }
    }

    struct GPU: Codable, Sendable {
        let name: String
        let usage: Double
        let memUsedMb: Double
        let memTotalMb: Double
        let tempC: Double
        let powerW: Double
        enum CodingKeys: String, CodingKey {
            case name, usage
            case memUsedMb = "mem_used_mb"
            case memTotalMb = "mem_total_mb"
            case tempC = "temp_c"
            case powerW = "power_w"
        }
        var memUsage: Double { memTotalMb > 0 ? memUsedMb / memTotalMb * 100 : 0 }
    }

    struct Disk: Codable, Sendable {
        let usedGb: Double
        let totalGb: Double
        let usage: Double
        enum CodingKeys: String, CodingKey {
            case usage
            case usedGb = "used_gb"
            case totalGb = "total_gb"
        }
    }

    struct Container: Codable, Sendable, Identifiable {
        let name: String
        let status: String
        let image: String?
        var id: String { name }
    }
}

extension Metrics {
    /// "3d 4h", "56m", "42s" — human uptime.
    var uptimeText: String {
        let s = uptimeS
        if s >= 86_400 { return "\(s / 86_400)d \((s % 86_400) / 3600)h" }
        if s >= 3_600 { return "\(s / 3_600)h \((s % 3_600) / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
