//
//  main.swift
//  SMC
//
//  Created by Serhiy Mytrovtsiy on 25/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

enum CMDType: String {
    case list
    case fans
    case help
    case unknown
    
    init(value: String) {
        switch value {
        case "list": self = .list
        case "fans": self = .fans
        case "help": self = .help
        default: self = .unknown
        }
    }
}

enum FlagsType: String {
    case temperature = "T"
    case voltage = "V"
    case power = "P"
    case fans = "F"
    case all
    
    init(value: String) {
        switch value {
        case "-t": self = .temperature
        case "-v": self = .voltage
        case "-p": self = .power
        case "-f": self = .fans
        default: self = .all
        }
    }
}

func main() {
    var args = CommandLine.arguments.dropFirst()
    let cmd = CMDType(value: args.first ?? "")
    args = args.dropFirst()
    
    switch cmd {
    case .list:
        var keys = SMC.shared.getAllKeys()
        args.forEach { (arg: String) in
            let flag = FlagsType(value: arg)
            if flag != .all {
                keys = keys.filter{ $0.hasPrefix(flag.rawValue)}
            }
        }
        
        print("[INFO]: found \(keys.count) keys\n")
        
        keys.forEach { (key: String) in
            let value = SMC.shared.getValue(key)
            print("[\(key)]    ", value ?? 0)
        }
    case .fans:
        guard let count = SMC.shared.getValue("FNum") else {
            print("FNum not found")
            return
        }
        print("Number of fans: \(count)\n")
        
        for i in 0..<Int(count) {
            print("\(i): \(SMC.shared.getStringValue("F\(i)ID") ?? "Fan #\(i)")")
            print("Actual speed:", SMC.shared.getValue("F\(i)Ac") ?? -1)
            print("Minimal speed:", SMC.shared.getValue("F\(i)Mn") ?? -1)
            print("Maximum speed:", SMC.shared.getValue("F\(i)Mx") ?? -1)
            print("Target speed:", SMC.shared.getValue("F\(i)Tg") ?? -1)
            print("Mode:", FanMode(rawValue: Int(SMC.shared.getValue(SMC.shared.fanModeKey(i)) ?? -1)) ?? .forced)
            
            print()
        }
    case .help, .unknown:
        print("SMC tool\n")
        print("Usage:")
        print("  ./smc [command]\n")
        print("Available Commands:")
        print("  list     list keys and values")
        print("  fans     list of fans")
        print("  help     help menu\n")
        print("Available Flags:")
        print("  -t    list temperature sensors")
        print("  -v    list voltage sensors")
        print("  -p    list power sensors")
        print("  -f    list fans\n")
    }
}

main()
