//
//  popup.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 22/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private var list: [String: NSView] = [:]
    
    private var unknownSensorsState: Bool { Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
    private var fanValueState: FanValue = .percentage
    
    private var sensors: [Sensor_p] = []
    private let settingsView: NSStackView = NSStackView()
    private let sensorsCache = PopupCache<[Sensor_p]>()
    
    public init() {
        super.init(ModuleType.sensors, frame: NSRect( x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.fanValueState = FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: self.fanValueState.rawValue)) ?? .percentage
        
        self.orientation = .vertical
        self.spacing = 0
        self.translatesAutoresizingMaskIntoConstraints = false
        
        self.settingsView.orientation = .vertical
        self.settingsView.spacing = Constants.Settings.margin
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Fan value"), component: selectView(
                action: #selector(self.toggleFanValue),
                items: FanValues,
                selected: self.fanValueState.rawValue
            ))
        ]))
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func setup(_ values: [Sensor_p]? = nil, reload: Bool = false) {
        guard let values = reload ? self.sensors : values else { return }
        let fans = values.filter({ $0.type == .fan && $0.popupState })
        var sensors = values
        if !self.unknownSensorsState {
            sensors = sensors.filter({ $0.group != .unknown })
        }
        
        self.subviews.forEach({ $0.removeFromSuperview() })
        if !reload {
            self.settingsView.subviews.filter({ $0.identifier == NSUserInterfaceItemIdentifier("sensor") }).forEach { v in
                v.removeFromSuperview()
            }
        }
        
        if !fans.isEmpty {
            let separator = SeparatorView(label: localizedString("Fans"))
            separator.widthAnchor.constraint(equalToConstant: Constants.Popup.width).isActive = true
            self.addArrangedSubview(separator)
            
            let container = NSStackView()
            container.orientation = .vertical
            container.spacing = Constants.Popup.spacing
            
            fans.forEach { (f: Sensor_p) in
                if let fan = f as? Fan {
                    if f.isComputed {
                        let sensor = SensorView(fan, width: self.frame.width, toggleable: false) {}
                        self.list[fan.key] = sensor
                        container.addArrangedSubview(sensor)
                    } else {
                        let view = FanView(fan, width: self.frame.width) { [weak self] in
                            let h = container.arrangedSubviews.map({ $0.bounds.height + container.spacing }).reduce(0, +) - container.spacing
                            if container.frame.size.height != h && h >= 0 {
                                container.setFrameSize(NSSize(width: container.frame.width, height: h))
                            }
                            self?.recalculateHeight()
                        }
                        self.list[fan.key] = view
                        container.addArrangedSubview(view)
                    }
                }
            }
            
            let h = container.arrangedSubviews.map({ $0.bounds.height + container.spacing }).reduce(0, +) - container.spacing
            if container.frame.size.height != h {
                container.setFrameSize(NSSize(width: container.frame.width, height: h))
            }
            self.addArrangedSubview(container)
        }
        
        var types: [SensorType] = []
        sensors.forEach { (s: Sensor_p) in
            if !types.contains(s.type) {
                types.append(s.type)
            }
        }
        
        types.forEach { (typ: SensorType) in
            var filtered = sensors.filter{ $0.type == typ }
            var groups: [SensorGroup] = []
            filtered.forEach { (s: Sensor_p) in
                if !groups.contains(s.group) {
                    groups.append(s.group)
                }
            }
            
            if !reload {
                let section = PreferencesSection(title: localizedString(typ.rawValue))
                section.identifier = NSUserInterfaceItemIdentifier("sensor")
                groups.forEach { (group: SensorGroup) in
                    filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                        let btn = switchView(
                            action: #selector(self.toggleSensor),
                            state: s.popupState
                        )
                        btn.identifier = NSUserInterfaceItemIdentifier(rawValue: s.key)
                        section.add(PreferencesRow(localizedString(s.name), component: btn))
                    }
                }
                self.settingsView.addArrangedSubview(section)
            }
            
            if typ == .fan { return }
            filtered = filtered.filter{ $0.popupState }
            if filtered.isEmpty { return }
            
            self.addArrangedSubview(separatorView(localizedString(typ.rawValue), width: self.frame.width))
            groups.forEach { (group: SensorGroup) in
                filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                    let sensor = SensorView(s, width: self.frame.width) { [weak self] in
                        self?.recalculateHeight()
                    }
                    self.addArrangedSubview(sensor)
                    self.list[s.key] = sensor
                }
            }
        }
        
        if !reload {
            self.sensors = values
        }
        self.recalculateHeight()
    }
    
    internal func usageCallback(_ values: [Sensor_p]) {
        DispatchQueue.main.async(execute: {
            values.filter({ $0 is Sensor }).forEach { (s: Sensor_p) in
                if let sensor = self.list[s.key] as? SensorView {
                    sensor.addHistoryPoint(s)
                }
            }
            
            self.sensorsCache.apply(values, visible: self.window?.isVisible ?? false, render: self.renderSensors)
        })
    }
    
    private func renderSensors(_ values: [Sensor_p]) {
        values.forEach { (s: Sensor_p) in
            switch self.list[s.key] {
            case let fan as FanView:
                if let f = s as? Fan {
                    fan.update(f)
                }
            case let sensor as SensorView:
                sensor.update(s)
            case .none, .some:
                break
            }
        }
    }
    
    public override func appear() {
        self.replay(self.sensorsCache, render: self.renderSensors)
    }
    
    private func recalculateHeight() {
        let h = self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +) - self.spacing
        if self.frame.size.height != h {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        self.settingsView
    }
    
    @objc private func toggleFanValue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String, let value = FanValue(rawValue: key) {
            self.fanValueState = value
            Store.shared.set(key: "Sensors_popup_fanValue", value: self.fanValueState.rawValue)
        }
    }
    
    // MARK: helpers
    
    @objc private func toggleSensor(_ sender: NSControl) {
        guard let id = sender.identifier else { return }
        Store.shared.set(key: "sensor_\(id.rawValue)_popup", value: controlState(sender))
        self.setup(reload: true)
    }
    
}

// MARK: - Sensor view

internal class SensorView: NSStackView {
    public var sizeCallback: (() -> Void)
    
    private var valueView: ValueSensorView!
    private var chartView: ChartSensorView!
    
    private var openned: Bool = false
    
    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.percentage.rawValue)) ?? .percentage
    }
    
    public init(_ sensor: Sensor_p, width: CGFloat, toggleable: Bool = true, callback: @escaping (() -> Void)) {
        self.sizeCallback = callback
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        
        self.orientation = .vertical
        self.distribution = .fillProportionally
        self.spacing = 0
        
        self.valueView = ValueSensorView(sensor, width: width, toggleable: toggleable, callback: { [weak self] in
            self?.open()
        })
        self.chartView = ChartSensorView(width: width, suffix: sensor.unit)
        
        self.addArrangedSubview(self.valueView)
        
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: self.bounds.width)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ sensor: Sensor_p) {
        var value = sensor.formattedPopupValue
        if let fan = sensor as? Fan {
            value = self.fanValueState == .percentage ? "\(fan.percentage)%" : fan.formattedValue
        }
        self.valueView.update(value)
    }
    
    public func addHistoryPoint(_ sensor: Sensor_p) {
        self.chartView.update(sensor.localValue, sensor.unit)
    }
    
    private func open() {
        if self.openned {
            self.chartView.removeFromSuperview()
        } else {
            self.addArrangedSubview(self.chartView)
        }
        self.openned = !self.openned
        
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback()
    }
}

internal class ValueSensorView: NSStackView {
    public var callback: (() -> Void)
    
    private var labelView: LabelField = {
        let view = LabelField(frame: NSRect.zero)
        view.cell?.truncatesLastVisibleLine = true
        return view
    }()
    private var valueView: ValueField = ValueField(frame: NSRect.zero)
    
    private let isToggleable: Bool
    
    public init(_ sensor: Sensor_p, width: CGFloat, toggleable: Bool = true, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.isToggleable = toggleable
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        
        self.wantsLayer = true
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        self.labelView.stringValue = sensor.name
        self.labelView.toolTip = sensor.key
        self.valueView.stringValue = sensor.formattedValue
        
        self.addArrangedSubview(self.labelView)
        self.addArrangedSubview(self.valueView)
        
        if self.isToggleable {
            self.addTrackingArea(NSTrackingArea(
                rect: NSRect(x: 0, y: 0, width: self.frame.width, height: 22),
                options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }
        
        NSLayoutConstraint.activate([
            self.labelView.heightAnchor.constraint(equalToConstant: 16),
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ value: String) {
        self.valueView.stringValue = value
    }
    
    override func mouseDown(with theEvent: NSEvent) {
        guard self.isToggleable else { return }
        self.callback()
    }
    
    public override func mouseEntered(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.05)
    }
    
    public override func mouseExited(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .none
    }
}

internal class ChartSensorView: NSStackView {
    private var chart: LineChartView? = nil
    private var currentSuffix: String
    
    public init(width: CGFloat, suffix: String) {
        self.currentSuffix = suffix
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        self.chart = LineChartView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height), num: 120, scale: .linear)
        self.chart?.setSuffix(suffix)
        
        if let view = self.chart {
            self.addArrangedSubview(view)
        }
        
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ value: Double, _ suffix: String) {
        guard let chart = self.chart else { return }
        if self.currentSuffix != suffix {
            self.currentSuffix = suffix
            chart.setSuffix(suffix)
        }
        chart.addValue(value/100)
    }
}

// MARK: - Fan view

internal class FanView: NSStackView {
    public var sizeCallback: (() -> Void)
    
    internal var fan: Fan
    private var ready: Bool = false
    
    private var valueField: NSTextField? = nil
    private var barView: BarChartView = BarChartView(size: 6, horizontal: true)
    
    private var fanValue: FanValue {
        FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.percentage.rawValue)) ?? .percentage
    }
    
    private var horizontalMargin: CGFloat {
        self.edgeInsets.top + self.edgeInsets.bottom + (self.spacing*CGFloat(self.arrangedSubviews.count))
    }
    
    public init(_ fan: Fan, width: CGFloat, callback: @escaping (() -> Void)) {
        self.fan = fan
        self.sizeCallback = callback
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))

        self.orientation = .vertical
        self.alignment = .centerX
        self.distribution = .fillProportionally
        self.spacing = 1
        self.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        
        self.nameAndSpeed()
        self.resize()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func nameAndSpeed() {
        let row: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 16))
        row.widthAnchor.constraint(equalToConstant: self.frame.width).isActive = true
        row.heightAnchor.constraint(equalToConstant: row.bounds.height).isActive = true
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 0
        
        let nameField: NSTextField = TextView()
        nameField.stringValue = self.fan.name
        nameField.toolTip = self.fan.key
        nameField.cell?.truncatesLastVisibleLine = true
        
        let value = self.fan.value
        let valueField: NSTextField = TextView()
        valueField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        valueField.alignment = .right
        valueField.stringValue = self.fanValue == .percentage ? "\(self.fan.percentage)%" : self.fan.formattedValue
        valueField.toolTip = "\(value)"
        
        let percentage = self.fan.percentage < 0 ? 0 : self.fan.percentage
        self.barView.widthAnchor.constraint(equalToConstant: 110).isActive = true
        self.barView.setValue(ColorValue(Double(percentage) / 100))
        
        row.addArrangedSubview(nameField)
        row.addArrangedSubview(self.barView)
        row.addArrangedSubview(valueField)
        
        self.valueField = valueField
        
        self.addArrangedSubview(row)
    }

    public func update(_ value: Fan) {
        DispatchQueue.main.async(execute: {
            if (self.window?.isVisible ?? false) || !self.ready {
                self.fan.value = value.value
                
                var newValue = ""
                if value.value != 1 {
                    if self.fan.maxSpeed == 1 || self.fan.maxSpeed == 0 {
                        newValue = "\(Int(value.value)) RPM"
                    } else {
                        newValue = self.fanValue == .percentage ? "\(value.percentage)%" : value.formattedValue
                    }
                }
                
                self.valueField?.stringValue = newValue
                self.valueField?.toolTip = value.formattedValue
                
                let percentage = value.percentage < 0 ? 0 : value.percentage
                self.barView.setValue(ColorValue(Double(percentage) / 100))

                self.ready = true
            }
        })
    }

    private func resize() {
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h + self.horizontalMargin))
        self.sizeCallback()
    }
}
