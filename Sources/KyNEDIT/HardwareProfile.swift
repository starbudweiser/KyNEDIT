import Foundation
import IOKit

enum StorageKind: String, Sendable { case internalSSD, externalSSD, externalHDD, network, unknown }

/// Machine détectée au lancement : puce, cœurs, mémoire, moteurs média (estimés d'après le nom de la puce, confirmés par le banc d'essai).
struct HardwareProfile: Sendable {
    var chip = "?"
    var model = "?"
    var perfCores = 0, effCores = 0, gpuCores = 0
    var memoryGB = 0
    var videoEngines = 1      // moteurs d'encodage H.264/HEVC (estimation)
    var proResEngines = 0     // moteurs ProRes (estimation)

    static let current: HardwareProfile = detect()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0; var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    private static func gpuCoreCount() -> Int {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        let v = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Int) ?? 0
    }

    static func detect() -> HardwareProfile {
        var p = HardwareProfile()
        p.chip = sysctlString("machdep.cpu.brand_string") ?? "?"
        p.model = sysctlString("hw.model") ?? "?"
        p.perfCores = sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 0
        p.effCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        p.memoryGB = Int((Double(sysctlInt("hw.memsize") ?? 0) / 1_073_741_824).rounded())
        p.gpuCores = gpuCoreCount()
        let name = p.chip
        if name.contains("Ultra") { p.videoEngines = 4; p.proResEngines = 4 }
        else if name.contains("Max") { p.videoEngines = 2; p.proResEngines = 2 }
        else if name.contains("Pro") { p.videoEngines = 1; p.proResEngines = 1 }
        else { p.videoEngines = 1; p.proResEngines = 0 }
        return p
    }
}

/// Répartition du travail : combien de tâches lourdes en parallèle selon la machine, le disque et la température.
enum Scheduler {
    /// 1.0 normal ; réduit quand la machine chauffe ou en mode économie d'énergie.
    static var thermalFactor: Double {
        var f = 1.0
        switch ProcessInfo.processInfo.thermalState {
        case .fair: f = 0.75
        case .serious: f = 0.5
        case .critical: f = 0.25
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { f *= 0.5 }
        return f
    }

    private static func scaled(_ n: Int) -> Int { max(1, Int((Double(n) * thermalFactor).rounded())) }

    /// Dossiers lus en parallèle pendant l'analyse.
    static func scanWorkers(for path: String) -> Int {
        let base: Int
        switch StorageProbe.kind(of: path) {
        case .internalSSD: base = 16
        case .externalSSD: base = 8
        case .externalHDD: base = 2
        case .network: base = 4
        case .unknown: base = 8
        }
        return scaled(base)
    }

    /// Vignettes et lectures d'en-têtes en parallèle : les cœurs de performance.
    static var thumbSlots: Int { scaled(max(2, HardwareProfile.current.perfCores)) }

    /// Exports simultanés par type de codec : un par moteur (estimation, remplacée par la mesure du banc d'essai).
    static func exportSlots(proRes: Bool) -> Int {
        let p = HardwareProfile.current
        if let measured = BenchStore.load()?.bestSessions[proRes ? "ProRes 422 HQ" : "HEVC"] { return scaled(measured) }
        return scaled(proRes ? max(1, p.proResEngines) : max(1, p.videoEngines))
    }
}

/// Type de stockage d'un chemin (mis en cache par volume).
enum StorageProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: StorageKind] = [:]

    static func mountPoint(of path: String) -> String {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]).volume?.path) ?? "/"
    }

    static func kind(of path: String) -> StorageKind {
        let mount = mountPoint(of: path)
        lock.lock(); if let k = cache[mount] { lock.unlock(); return k }; lock.unlock()
        let k = detect(mount)
        lock.lock(); cache[mount] = k; lock.unlock()
        return k
    }

    private static func detect(_ mount: String) -> StorageKind {
        let url = URL(fileURLWithPath: mount)
        if let v = try? url.resourceValues(forKeys: [.volumeIsLocalKey]), v.volumeIsLocal == false { return .network }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", mount]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return .unknown }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertySerialization(data) else { return .unknown }
        let internalDisk = plist["Internal"] as? Bool ?? false
        let solid = plist["SolidState"] as? Bool
        if internalDisk { return .internalSSD }
        if solid == false { return .externalHDD }
        return solid == true ? .externalSSD : .unknown
    }

    /// Dictionnaire d'une liste de propriétés.
    private static func PropertySerialization(_ d: Data) throws -> [String: Any] {
        (try PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any]) ?? [:]
    }
}
