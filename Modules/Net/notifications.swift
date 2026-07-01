//
//  notifications.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 25/01/2025
//  Using Swift 6.0
//  Running on macOS 15.1
//
//  Copyright © 2025 Serhiy Mytrovtsiy. All rights reserved.
//  

import Cocoa
import Kit

class Notifications: NotificationsWrapper {
    private let interfaceID: String = "interface"
    private let localID: String = "localIP"
    private let wifiID: String = "wifi"
    
    private var interfaceState: Bool = false
    private var localIPState: Bool = false
    private var wifiState: Bool = false
    
    private var interface: String?
    private var localIP: String?
    private var wifi: String?
    
    private var localIPCount: Int = 0
    private var localIPThreshold: Int = 3
    
    private var interfaceInit: Bool = false
    private var localIPInit: Bool = false
    private var wifiInit: Bool = false
    
    public init(_ module: ModuleType) {
        super.init(module, [self.interfaceID, self.localID, self.wifiID])
        
        self.interfaceState = Store.shared.bool(key: "\(self.module)_notifications_interface_state", defaultValue: self.interfaceState)
        self.localIPState = Store.shared.bool(key: "\(self.module)_notifications_localIP_state", defaultValue: self.localIPState)
        self.wifiState = Store.shared.bool(key: "\(self.module)_notifications_wifi_state", defaultValue: self.wifiState)
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Network interface"), component: switchView(
                action: #selector(self.toggleInterfaceState),
                state: self.interfaceState
            )),
            PreferencesRow(localizedString("Local IP"), component: switchView(
                action: #selector(self.toggleLocalIPState),
                state: self.localIPState
            )),
            PreferencesRow(localizedString("WiFi network"), component: switchView(
                action: #selector(self.toggleWiFiState),
                state: self.wifiState
            ))
        ]))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func usageCallback(_ value: Network_Usage) {
        if !self.interfaceInit {
            self.interface = value.interface?.BSDName
            self.interfaceInit = true
        }
        if !self.localIPInit {
            if let v4 = value.laddr.v4 {
                self.localIP = v4
                self.localIPInit = true
            } else if let v6 = value.laddr.v6 {
                self.localIP = v6
                self.localIPInit = true
            }
        }
        if !self.wifiInit {
            self.wifi = value.wifiDetails.ssid
            self.wifiInit = true
        }
        
        if self.interfaceState {
            if value.interface?.BSDName != self.interface {
                self.newNotification(id: self.interfaceID, title: localizedString("Network interface changed"), subtitle: nil)
            }
            self.interface = value.interface?.BSDName
        }
        
        if self.localIPState {
            let addr = value.laddr.v4 ?? value.laddr.v6
            if addr != self.localIP {
                self.localIPCount += 1
                if self.localIPCount >= self.localIPThreshold {
                    var subtitle = ""
                    if let prev = self.localIP {
                        subtitle = localizedString("Previous IP", prev)
                    }
                    if let new = addr {
                        if !subtitle.isEmpty {
                            subtitle += "\n"
                        }
                        subtitle += localizedString("New IP", new)
                    }
                    self.newNotification(id: self.localID, title: localizedString("Local IP changed"), subtitle: subtitle)
                    self.localIP = addr
                    self.localIPCount = 0
                }
            } else {
                self.localIPCount = 0
            }
        }
        
        if self.wifiState {
            if value.wifiDetails.ssid != self.wifi {
                self.newNotification(id: self.wifiID, title: localizedString("WiFi network changed"), subtitle: nil)
            }
            self.wifi = value.wifiDetails.ssid
        }
    }
    
    @objc private func toggleInterfaceState(_ sender: NSControl) {
        self.interfaceState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_interface_state", value: self.interfaceState)
    }
    @objc private func toggleLocalIPState(_ sender: NSControl) {
        self.localIPState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_localIP_state", value: self.localIPState)
    }
    @objc private func toggleWiFiState(_ sender: NSControl) {
        self.wifiState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_wifi_state", value: self.wifiState)
    }
}
