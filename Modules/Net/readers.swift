//
//  readers.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 24/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SystemConfiguration
import CoreWLAN

// swiftlint:disable control_statement
extension CWPHYMode: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .mode11a:  return "802.11a"
        case .mode11ac: return "802.11ac"
        case .mode11b:  return "802.11b"
        case .mode11g:  return "802.11g"
        case .mode11n:  return "802.11n"
        case .mode11ax: return "802.11ax"
        case .mode11be: return "802.11be"
        case .modeNone: return "none"
        @unknown default: return "unknown"
        }
    }
}

extension CWInterfaceMode: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .hostAP:       return "AP"
        case .IBSS:         return "Adhoc"
        case .station:      return "Station"
        case .none:         return "none"
        @unknown default:   return "unknown"
        }
    }
}

extension CWSecurity: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .none:               return "none"
        case .WEP:                return "WEP"
        case .wpaPersonal:        return "WPA Personal"
        case .wpaPersonalMixed:   return "WPA Personal Mixed"
        case .wpa2Personal:       return "WPA2 Personal"
        case .personal:           return "Personal"
        case .dynamicWEP:         return "Dynamic WEP"
        case .wpaEnterprise:      return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA Enterprise Mixed"
        case .wpa2Enterprise:     return "WPA2 Enterprise"
        case .enterprise:         return "Enterprise"
        case .unknown:            return "unknown"
        case .wpa3Personal:       return "WPA3 Personal"
        case .wpa3Enterprise:     return "WPA3 Enterprise"
        case .wpa3Transition:     return "WPA3 Transition"
        default:                  return "unknown"
        }
    }
}

extension CWChannelBand: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .band2GHz:     return "2 GHz"
        case .band5GHz:     return "5 GHz"
        case .band6GHz:     return "6 GHz"
        case .bandUnknown:  return "unknown"
        @unknown default:   return "unknown"
        }
    }
}

extension CWChannelWidth: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .width20MHz:   return "20 MHz"
        case .width40MHz:   return "40 MHz"
        case .width80MHz:   return "80 MHz"
        case .width160MHz:  return "160 MHz"
        case .widthUnknown: return "unknown"
        @unknown default:   return "unknown"
        }
    }
}
// swiftlint:enable control_statement

extension CWChannel {
    override public var description: String {
        return "\(channelNumber) (\(channelBand), \(channelWidth))"
    }
}

internal class UsageReader: Reader<Network_Usage>, CWEventDelegate {
    private var reachability: Reachability = Reachability(start: true)
    private let variablesQueue = DispatchQueue(label: "eu.exelban.NetworkUsageReader")
    private var _usage: Network_Usage = Network_Usage()
    public var usage: Network_Usage {
        get { self.variablesQueue.sync { self._usage } }
        set { self.variablesQueue.sync { self._usage = newValue } }
    }
    
    private var primaryInterface: String {
        get {
            if let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString), let name = global["PrimaryInterface"] as? String {
                return name
            }
            return ""
        }
    }
    
    private var interfaceID: String {
        get { Store.shared.string(key: "Network_interface", defaultValue: self.primaryInterface) }
        set { Store.shared.set(key: "Network_interface", value: newValue) }
    }
    
    private var reader: String {
        get { Store.shared.string(key: "Network_reader", defaultValue: "interface") }
    }
    
    private var vpnConnection: Bool {
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any], let scopes = settings["__SCOPED__"] as? [String: Any] {
            return !scopes.filter({ $0.key.contains("tap") || $0.key.contains("tun") || $0.key.contains("ppp") || $0.key.contains("ipsec") || $0.key.contains("ipsec0")}).isEmpty
        }
        return false
    }
    
    private var VPNMode: Bool {
        get { Store.shared.bool(key: "Network_VPNMode", defaultValue: false) }
    }
    private var usageResetInterval: AppUpdateInterval? {
        AppUpdateInterval(rawValue: Store.shared.string(key: "Network_usageReset", defaultValue: AppUpdateInterval.never.rawValue))
    }
    private var nextUsageResetDate: Date? {
        get {
            let ts = Store.shared.int(key: "Network_usageReset_next", defaultValue: 0)
            return ts == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(ts))
        }
        set {
            if let newValue {
                Store.shared.set(key: "Network_usageReset_next", value: Int(newValue.timeIntervalSince1970))
            } else {
                Store.shared.remove("Network_usageReset_next")
            }
        }
    }
    
    private let wifiClient = CWWiFiClient.shared()
    
    private var lastDetailsReadTS: Date = .distantPast
    
    public override func setup() {
        self.reachability.reachable = { [weak self] in
            guard let self else { return }
            if self.active {
                self.getDetails()
                self.getWiFiDetails()
            }
        }
        self.reachability.unreachable = { [weak self] in
            guard let self else { return }
            if self.active {
                self.getWiFiDetails()
                self.usage.reset()
                self.callback(self.usage)
            }
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(resetTotalNetworkUsage), name: .resetTotalNetworkUsage, object: nil)
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if self.active {
                self.getDetails()
            }
        }
        
        if let usage = self.value {
            self.usage = usage
            self.usage.bandwidth = Bandwidth()
        }
        
        self.checkUsageReset()
        
        self.wifiClient.delegate = self
        self.startListeningForWifiEvents()
    }
    
    public override func terminate() {
        self.reachability.stop()
        self.reachability.reachable = {}
        self.reachability.unreachable = {}
        self.stopListeningForWifiEvents()
        self.wifiClient.delegate = nil
    }
    
    public override func read() {
        self.checkUsageReset()
        self.getDetails()
        
        let current: Bandwidth = self.reader == "interface" ? self.readInterfaceBandwidth() : self.readProcessBandwidth()
        
        // allows to reset the value to 0 when first read
        if self.usage.bandwidth.upload != 0 {
            self.usage.bandwidth.upload = current.upload - self.usage.bandwidth.upload
        }
        if self.usage.bandwidth.download != 0 {
            self.usage.bandwidth.download = current.download - self.usage.bandwidth.download
        }
        
        self.usage.bandwidth.upload = max(self.usage.bandwidth.upload, 0) // prevent negative upload value
        self.usage.bandwidth.download = max(self.usage.bandwidth.download, 0) // prevent negative download value
        
        // drop one-shot counter jumps (e.g. on reconnect) that exceed what the link can physically deliver
        let interval = self.interval ?? 1
        let maxDelta: Int64 = {
            if let rate = self.usage.interface?.transmitRate, rate > 0 {
                return Int64(rate * 1_000_000 / 8 * 1.5 * interval) // 50% headroom over negotiated link rate
            }
            return Int64(2_000_000_000 * interval) // 16 Gbps fallback when link rate is unknown
        }()
        if self.usage.bandwidth.upload > maxDelta { self.usage.bandwidth.upload = 0 }
        if self.usage.bandwidth.download > maxDelta { self.usage.bandwidth.download = 0 }
        
        self.usage.total.upload += self.usage.bandwidth.upload
        self.usage.total.download += self.usage.bandwidth.download
        
        self.usage.status = self.reachability.isReachable
        
        if self.vpnConnection && self.VPNMode {
            self.usage.bandwidth.upload /= 2
            self.usage.bandwidth.download /= 2
        }
        
        self.callback(self.usage)
        
        self.usage.bandwidth.upload = current.upload
        self.usage.bandwidth.download = current.download
    }
    
    private func readInterfaceBandwidth() -> Bandwidth {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>? = nil
        var totalUpload: Int64 = 0
        var totalDownload: Int64 = 0
        guard getifaddrs(&interfaceAddresses) == 0 else {
            return Bandwidth()
        }
        
        var pointer = interfaceAddresses
        while pointer != nil {
            defer { pointer = pointer?.pointee.ifa_next }
            guard let pointer = pointer else { break }
            
            if String(cString: pointer.pointee.ifa_name) != self.interfaceID {
                continue
            }
            self.usage.interface?.status = (pointer.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            
            if let wifiInterface = CWWiFiClient.shared().interface(withName: self.interfaceID) {
                self.usage.interface?.transmitRate = wifiInterface.transmitRate()
            } else if let raw = pointer.pointee.ifa_data {
                let dataPtr = raw.assumingMemoryBound(to: if_data.self)
                let ifData = dataPtr.pointee
                let baud = UInt64(ifData.ifi_baudrate)
                if baud > 0 {
                    self.usage.interface?.transmitRate = Double(baud) / 1_000_000.0
                }
            }
            
            self.getLocalIP(pointer)
            
            if let info = self.getBytesInfo(pointer) {
                totalUpload += info.upload
                totalDownload += info.download
            }
        }
        freeifaddrs(interfaceAddresses)
        
        return Bandwidth(upload: totalUpload, download: totalDownload)
    }
    
    private func readProcessBandwidth() -> Bandwidth {
        let task = Process()
        task.launchPath = "/usr/bin/nettop"
        task.arguments = ["-P", "-L", "1", "-n", "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"]
        task.environment = [
            "NSUnbufferedIO": "YES",
            "LC_ALL": "en_US.UTF-8"
        ]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        defer {
            if task.isRunning {
                task.terminate()
            }
            task.waitUntilExit()
            inputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
        } catch let err {
            error("read bandwidth from processes: \(err)", log: self.log)
            return Bandwidth()
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)
        _ = String(data: errorData, encoding: .utf8)
        guard let output, !output.isEmpty else { return Bandwidth() }
        
        var totalUpload: Int64 = 0
        var totalDownload: Int64 = 0
        var firstLine = false
        output.enumerateLines { (line, _) in
            if !firstLine {
                firstLine = true
                return
            }
            
            let parsedLine = line.split(separator: ",")
            guard parsedLine.count >= 3 else {
                return
            }
            
            if let download = Int64(parsedLine[1]) {
                totalDownload += download
            }
            if let upload = Int64(parsedLine[2]) {
                totalUpload += upload
            }
        }
        
        return Bandwidth(upload: totalUpload, download: totalDownload)
    }
    
    public func getDetails() {
        guard self.interfaceID != "" else { return }
        
        let now = Date()
        if now.timeIntervalSince(self.lastDetailsReadTS) < 15 { return }
        
        for interface in SCNetworkInterfaceCopyAll() as NSArray {
            if let bsdName = SCNetworkInterfaceGetBSDName(interface as! SCNetworkInterface), bsdName as String == self.interfaceID,
               let type = SCNetworkInterfaceGetInterfaceType(interface as! SCNetworkInterface),
               let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface as! SCNetworkInterface),
               let address = SCNetworkInterfaceGetHardwareAddressString(interface as! SCNetworkInterface) {
                self.usage.interface = Network_interface(displayName: displayName as String, BSDName: bsdName as String, address: address as String)
                
                switch type {
                case kSCNetworkInterfaceTypeEthernet:
                    self.usage.connectionType = .ethernet
                case kSCNetworkInterfaceTypeIEEE80211, kSCNetworkInterfaceTypeWWAN:
                    self.usage.connectionType = .wifi
                case kSCNetworkInterfaceTypeBluetooth:
                    self.usage.connectionType = .bluetooth
                default:
                    self.usage.connectionType = .other
                }
            }
        }
        
        if let prefs = SCPreferencesCreate(nil, "Stats" as CFString, nil), let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            for service in services {
                if let interface = SCNetworkServiceGetInterface(service), let name = SCNetworkInterfaceGetBSDName(interface), name as String == self.interfaceID,
                   let serviceID = SCNetworkServiceGetServiceID(service) {
                    let key = "State:/Network/Service/\(serviceID)/DNS" as CFString
                    if let settings = SCDynamicStoreCopyValue(nil, key) as? [String: Any] {
                        self.usage.dns = settings["ServerAddresses"] as? [String] ?? []
                    }
                }
            }
        }
        
        guard self.usage.interface != nil else { return }
        
        if self.usage.wifiDetails.ssid != nil && (self.usage.wifiDetails.ssid == "" || self.usage.wifiDetails.ssid == "<redacted>") {
            self.usage.wifiDetails.ssid = nil
        }
        
        if self.usage.connectionType == .wifi && self.usage.wifiDetails.ssid == nil || self.usage.wifiDetails.ssid == "" {
            self.getWiFiDetails()
        }
        
        self.lastDetailsReadTS = Date()
    }
    
    private func getWiFiDetails() {
        if let interface = CWWiFiClient.shared().interface(withName: self.interfaceID) {
            if let ssid = interface.ssid() {
                self.usage.wifiDetails.ssid = ssid
            } else if let cfg = interface.configuration(),
                      let set = (cfg.value(forKey: "networkProfiles") as? NSOrderedSet),
                      let first = set.firstObject as? CWNetworkProfile,
                      let raw = first.ssid, !raw.isEmpty {
                self.usage.wifiDetails.ssid = raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let bssid = interface.bssid() {
                self.usage.wifiDetails.bssid = bssid
            }
            if let cc = interface.countryCode() {
                self.usage.wifiDetails.countryCode = cc
            }
            
            self.usage.wifiDetails.RSSI = interface.rssiValue()
            self.usage.wifiDetails.noise = interface.noiseMeasurement()
            
            self.usage.wifiDetails.standard = interface.activePHYMode().description
            self.usage.wifiDetails.mode = interface.interfaceMode().description
            self.usage.wifiDetails.security = interface.security().description
            
            if let ch = interface.wlanChannel() {
                self.usage.wifiDetails.channel = ch.description
                
                self.usage.wifiDetails.channelBand = ch.channelBand.description
                self.usage.wifiDetails.channelWidth = ch.channelWidth.description
                self.usage.wifiDetails.channelNumber = ch.channelNumber.description
            }
        }
        
        if self.usage.wifiDetails.ssid == nil || self.usage.wifiDetails.ssid == "" {
            guard let res = process(path: "/usr/sbin/system_profiler", arguments: ["SPAirPortDataType", "-json"]) else {
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: Data(res.utf8), options: []) as? [String: Any] {
                    if let arr = json["SPAirPortDataType"] as? [[String: Any]],
                       let airport = arr.first(where: { $0["spairport_airport_interfaces"] != nil }),
                       let interfaces = airport["spairport_airport_interfaces"] as? [[String: Any]],
                       let interface = interfaces.first(where: { $0["_name"] as? String == self.interfaceID }),
                       let obj = interface["spairport_current_network_information"] as? [String: Any] {
                        
                        self.usage.wifiDetails.ssid = obj["_name"] as? String
                        self.usage.wifiDetails.countryCode = obj["spairport_network_country_code"] as? String
                        self.usage.wifiDetails.standard = obj["spairport_network_phymode"] as? String
                    }
                }
            } catch let err as NSError {
                error("error to parse system_profiler SPAirPortDataType: \(err.localizedDescription)")
                return
            }
        }
    }
    
    private func getLocalIP(_ pointer: UnsafeMutablePointer<ifaddrs>) {
        guard let ifaAddr = pointer.pointee.ifa_addr else { return }
        var addr = ifaAddr.pointee
        guard addr.sa_family == UInt8(AF_INET) || addr.sa_family == UInt8(AF_INET6) else { return}
        
        var ip = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(&addr, socklen_t(addr.sa_len), &ip, socklen_t(ip.count), nil, socklen_t(0), NI_NUMERICHOST)
        
        let ipStr = String(cString: ip)
        if addr.sa_family == UInt8(AF_INET) && !ipStr.isEmpty {
            self.usage.laddr.v4 = ipStr
        } else if addr.sa_family == UInt8(AF_INET6) && !ipStr.isEmpty {
            self.usage.laddr.v6 = ipStr
        }
    }
    
    private func getBytesInfo(_ pointer: UnsafeMutablePointer<ifaddrs>) -> (upload: Int64, download: Int64)? {
        guard let addrPtr = pointer.pointee.ifa_addr, addrPtr.pointee.sa_family == UInt8(AF_LINK) else {
            return nil
        }
        guard let raw = pointer.pointee.ifa_data else { return nil }
        let data = raw.assumingMemoryBound(to: if_data.self)
        return (upload: Int64(data.pointee.ifi_obytes), download: Int64(data.pointee.ifi_ibytes))
    }
    
    private func nextUsageReset(after date: Date) -> Date? {
        let cal = Calendar.current
        switch self.usageResetInterval {
        case .oncePerDay:
            return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date))
        case .oncePerWeek:
            guard let start = cal.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
            return cal.date(byAdding: .weekOfYear, value: 1, to: start)
        case .oncePerMonth:
            guard let start = cal.dateInterval(of: .month, for: date)?.start else { return nil }
            return cal.date(byAdding: .month, value: 1, to: start)
        default:
            return nil
        }
    }
    
    private func checkUsageReset() {
        switch self.usageResetInterval {
        case .oncePerDay, .oncePerWeek, .oncePerMonth: break
        default: return
        }
        
        guard let next = self.nextUsageResetDate else {
            self.nextUsageResetDate = self.nextUsageReset(after: Date())
            return
        }
        
        if Date() >= next {
            self.resetTotalNetworkUsage()
        }
    }
    
    @objc func resetTotalNetworkUsage() {
        self.usage.total = Bandwidth()
        self.save(self.usage)
        self.nextUsageResetDate = self.nextUsageReset(after: Date())
    }
    
    private func startListeningForWifiEvents() {
        do {
            try self.wifiClient.startMonitoringEvent(with: .ssidDidChange)
        } catch let err as NSError {
            error("failed to start monitoring Wi-Fi events: \(err.localizedDescription)")
        }
    }
    
    private func stopListeningForWifiEvents() {
        do {
            try self.wifiClient.stopMonitoringEvent(with: .ssidDidChange)
        } catch let err as NSError {
            error("failed to stop monitoring Wi-Fi events: \(err.localizedDescription)")
        }
    }
    
    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        self.getWiFiDetails()
    }
}

public class ProcessReader: Reader<[Network_Process]> {
    private let title: String = "Network"
    private var previous: [Network_Process] = []
    
    private var numberOfProcesses: Int {
        get {
            return Store.shared.int(key: "\(self.title)_processes", defaultValue: 8)
        }
    }
    
    public override func setup() {
        self.popup = true
    }
    
    public override func read() {
        if self.numberOfProcesses == 0 {
            return
        }
        
        let task = Process()
        task.launchPath = "/usr/bin/nettop"
        task.arguments = ["-P", "-L", "1", "-n", "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"]
        task.environment = [
            "NSUnbufferedIO": "YES",
            "LC_ALL": "en_US.UTF-8"
        ]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        defer {
            if task.isRunning {
                task.terminate()
            }
            task.waitUntilExit()
            inputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
        } catch let error {
            print(error)
            return
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)
        _ = String(data: errorData, encoding: .utf8)
        guard let output, !output.isEmpty else { return }
        
        var list: [Network_Process] = []
        var firstLine = false
        output.enumerateLines { (line, _) in
            if !firstLine {
                firstLine = true
                return
            }
            
            let parsedLine = line.split(separator: ",")
            guard parsedLine.count >= 3 else {
                return
            }
            
            var process = Network_Process()
            process.time = Date()
            
            let nameArray = parsedLine[0].split(separator: ".")
            if let pid = nameArray.last {
                process.pid = Int(pid) ?? 0
            }
            if let app = NSRunningApplication(processIdentifier: pid_t(process.pid) ) {
                process.name = app.localizedName ?? nameArray.dropLast().joined(separator: ".")
            } else {
                process.name = nameArray.dropLast().joined(separator: ".")
            }
            
            if process.name == "" {
                process.name = "\(process.pid)"
            }
            
            if let download = Int(parsedLine[1]) {
                process.download = download
            }
            if let upload = Int(parsedLine[2]) {
                process.upload = upload
            }
            
            list.append(process)
        }
        
        var processes: [Network_Process] = []
        if self.previous.isEmpty {
            self.previous = list
            processes = list
        } else {
            self.previous.forEach { (pp: Network_Process) in
                if let i = list.firstIndex(where: { $0.pid == pp.pid }) {
                    let p = list[i]
                    
                    var download = p.download - pp.download
                    var upload = p.upload - pp.upload
                    let time = download == 0 && upload == 0 ? pp.time : Date()
                    list[i].time = time
                    
                    if download < 0 {
                        download = 0
                    }
                    if upload < 0 {
                        upload = 0
                    }
                    
                    processes.append(Network_Process(pid: p.pid, name: p.name, time: time, download: download, upload: upload))
                }
            }
            self.previous = list
        }
        
        processes.sort {
            let firstMax = max($0.download, $0.upload)
            let secondMax = max($1.download, $1.upload)
            let firstMin = min($0.download, $0.upload)
            let secondMin = min($1.download, $1.upload)
            
            if firstMax == secondMax && firstMin == secondMin { // download and upload values are the same, sort by time
                return $0.time < $1.time
            } else if firstMax == secondMax && firstMin != secondMin { // max values are the same, min not. Sort by min values
                return firstMin < secondMin
            }
            return firstMax < secondMax // max values are not the same, sort by max value
        }
        
        self.callback(processes.suffix(self.numberOfProcesses).reversed())
    }
}

