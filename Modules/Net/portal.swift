//
//  portal.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 18/02/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public class Portal: PortalWrapper {
    private var chart: NetworkChartView? = nil
    
    private var localIPField: NSTextField? = nil
    
    private var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(self.name)_base", defaultValue: "byte")) ?? .byte
    }
    private var speedUnit: String {
        networkSpeedUnit(from: Store.shared.string(key: "\(self.name)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
    }
    private var reverseOrderState: Bool {
        Store.shared.bool(key: "\(self.name)_reverseOrder", defaultValue: false)
    }
    private var chartScale: Scale {
        Scale.fromString(Store.shared.string(key: "\(self.name)_chartScale", defaultValue: Scale.none.key))
    }
    private var chartFixedScale: Int {
        Store.shared.int(key: "\(self.name)_chartFixedScale", defaultValue: 12)
    }
    private var chartFixedScaleSize: SizeUnit {
        SizeUnit.fromString(Store.shared.string(key: "\(self.name)_chartFixedScaleSize", defaultValue: SizeUnit.MB.key))
    }
    private var downloadColor: NSColor {
        let v = SColor.fromString(Store.shared.string(key: "\(self.name)_downloadColor", defaultValue: SColor.secondBlue.key))
        var value = NSColor.systemBlue
        if let color = v.additional as? NSColor {
            value = color
        }
        return value
    }
    private var uploadColor: NSColor {
        let v = SColor.fromString(Store.shared.string(key: "\(self.name)_uploadColor", defaultValue: SColor.secondRed.key))
        var value = NSColor.systemRed
        if let color = v.additional as? NSColor {
            value = color
        }
        return value
    }
    
    public override func load() {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fill
        view.spacing = Constants.Popup.spacing*2
        view.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Constants.Popup.spacing*2,
            bottom: 0,
            right: Constants.Popup.spacing*2
        )
        
        let container: NSView = NSView(frame: CGRect(x: 0, y: 0, width: self.frame.width - (Constants.Popup.spacing*8), height: 68))
        container.wantsLayer = true
        container.layer?.cornerRadius = 3
        
        let chart = NetworkChartView(
            frame: CGRect(x: 0, y: 0, width: self.frame.width - (Constants.Popup.spacing*8), height: 68),
            num: 120,
            reversedOrder: self.reverseOrderState,
            outColor: self.uploadColor,
            inColor: self.downloadColor,
            scale: self.chartScale,
            fixedScale: Double(self.chartFixedScaleSize.toBytes(self.chartFixedScale))
        )
        chart.setBase(self.base)
        chart.setSpeedUnit(self.speedUnit)
        container.addSubview(chart)
        self.chart = chart
        view.addArrangedSubview(container)
        
        let localIP = portalRow(view, title: "\(localizedString("Local IP")):", value: localizedString("Unknown"), isSelectable: true)
        self.localIPField = localIP.1
        localIP.2.heightAnchor.constraint(equalToConstant: 16).isActive = true
        
        self.addArrangedSubview(view)
    }
    
    public func usageCallback(_ value: Network_Usage) {
        DispatchQueue.main.async(execute: {
            if let chart = self.chart {
                chart.setBase(self.base)
                chart.setSpeedUnit(self.speedUnit)
                chart.addValue(upload: Double(value.bandwidth.upload), download: Double(value.bandwidth.download))
                chart.setScale(self.chartScale, Double(self.chartFixedScaleSize.toBytes(self.chartFixedScale)))
                chart.setColors(in: self.downloadColor, out: self.uploadColor)
            }
            
            var privateIP = localizedString("Unknown")
            if let v4 = value.laddr.v4, !v4.isEmpty {
                privateIP = v4
            } else if let v6 = value.laddr.v6, !v6.isEmpty {
                privateIP = v6
            }
            if self.localIPField?.stringValue != privateIP {
                self.localIPField?.stringValue = privateIP
            }
        })
    }
}
