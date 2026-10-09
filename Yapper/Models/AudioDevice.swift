//
//  AudioDevice.swift
//  Yapper
//
//  Created on 2026-01-07.
//

import Foundation
import AVFoundation
import CoreAudio
import IOKit

/// Represents an audio input device
struct AudioDevice: Identifiable, Codable, Equatable {
    /// Unique device identifier
    let id: String
    
    /// Device name (e.g., "MacBook Pro Microphone")
    let name: String
    
    /// Device manufacturer
    let manufacturer: String?
    
    /// Whether this is the system default device
    let isDefault: Bool
    
    /// Whether the device is currently active/selected
    var isActive: Bool
    
    /// Number of input channels
    let channels: Int
    
    /// Supported sample rate
    let sampleRate: Double
    
    /// Device type (built-in, USB, Bluetooth, etc.)
    let deviceType: AudioDeviceType
    
    /// Whether the device is currently connected
    var isConnected: Bool
    
    // MARK: - Initialization
    
    init(
        id: String,
        name: String,
        manufacturer: String? = nil,
        isDefault: Bool = false,
        isActive: Bool = false,
        channels: Int = 1,
        sampleRate: Double = 48000.0,
        deviceType: AudioDeviceType = .builtin,
        isConnected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isDefault = isDefault
        self.isActive = isActive
        self.channels = channels
        self.sampleRate = sampleRate
        self.deviceType = deviceType
        self.isConnected = isConnected
    }
    
    // MARK: - Computed Properties
    
    /// Display name with manufacturer
    var fullName: String {
        if let manufacturer = manufacturer, !manufacturer.isEmpty {
            return "\(manufacturer) - \(name)"
        }
        return name
    }
    
    /// Short description of device capabilities
    var description: String {
        let channelText = channels == 1 ? "Mono" : "\(channels) channels"
        let rateText = "\(Int(sampleRate / 1000))kHz"
        return "\(channelText), \(rateText)"
    }
    
    /// Icon name for device type
    var iconName: String {
        deviceType.iconName
    }
}

// MARK: - Audio Device Type

/// Type of audio input device
enum AudioDeviceType: String, Codable, Equatable {
    case builtin = "Built-in"
    case usb = "USB"
    case bluetooth = "Bluetooth"
    case aggregate = "Aggregate"
    case virtual = "Virtual"
    case unknown = "Unknown"
    
    var iconName: String {
        switch self {
        case .builtin:
            return "laptopcomputer"
        case .usb:
            return "cable.connector"
        case .bluetooth:
            return "wave.3.right"
        case .aggregate:
            return "rectangle.stack"
        case .virtual:
            return "waveform.circle"
        case .unknown:
            return "mic"
        }
    }
    
    var displayName: String {
        rawValue
    }
}

// MARK: - Factory Methods

extension AudioDevice {
    // Factory method removed as AVAudioSessionPortDescription is unavailable on macOS

    
    /// System default device
    static var systemDefault: AudioDevice {
        AudioDevice(
            id: "system-default",
            name: "System Default",
            isDefault: true,
            deviceType: .builtin
        )
    }
}

// MARK: - Audio Device Preferences

/// User preferences for audio device selection
struct AudioDevicePreferences: Codable, Equatable {
    /// Input mode
    var inputMode: InputMode
    
    /// Selected device ID (when using custom device)
    var selectedDeviceId: String?
    
    /// Priority order of device IDs (when using prioritized mode)
    var priorityOrder: [String]
    
    /// Whether to automatically switch to new devices
    var autoSwitchToNewDevices: Bool
    
    // MARK: - Default
    
    static let `default` = AudioDevicePreferences(
        inputMode: .systemDefault,
        selectedDeviceId: nil,
        priorityOrder: [],
        autoSwitchToNewDevices: false
    )
}

// MARK: - Input Mode

/// Mode for selecting audio input device
enum InputMode: String, Codable, CaseIterable, Identifiable {
    case systemDefault = "System Default"
    case customDevice = "Custom Device"
    case prioritized = "Prioritized"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .systemDefault:
            return "Use system's default input device"
        case .customDevice:
            return "Select a specific input device"
        case .prioritized:
            return "Set up device priority order"
        }
    }
    
    var iconName: String {
        switch self {
        case .systemDefault:
            return "square.stack.3d.up"
        case .customDevice:
            return "mic.fill"
        case .prioritized:
            return "list.number"
        }
    }
}


// MARK: - Automatic Input

/// Picks the input when the user has not chosen one. AirPods and other Bluetooth mics switch the
/// headset to a low-quality call profile, so an open MacBook's built-in mic is used instead.
enum AutomaticInput {
    static func choose(defaultUID: String?, defaultTransport: UInt32?, builtInUID: String?, lidOpen: Bool) -> String? {
        let bluetooth = defaultTransport == kAudioDeviceTransportTypeBluetooth
            || defaultTransport == kAudioDeviceTransportTypeBluetoothLE
        guard bluetooth, lidOpen, let builtInUID else { return defaultUID }
        return builtInUID
    }

    /// The Core Audio UID of the automatic input, which matches AVCaptureDevice.uniqueID.
    static func currentUID() -> String? {
        var device = AudioDeviceID(0)
        let defaultID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &device) ? device : nil
        let builtIn = deviceIDs().first {
            transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0)
        }
        return choose(defaultUID: defaultID.flatMap(uid), defaultTransport: defaultID.flatMap(transport),
                      builtInUID: builtIn.flatMap(uid), lidOpen: lidOpen())
    }

    /// Desktops have no clamshell state, so a missing value counts as open.
    static func lidOpen() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return true }
        defer { IOObjectRelease(service) }
        let closed = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return closed != true
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout UInt32) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func transport(_ device: AudioDeviceID) -> UInt32? {
        var value: UInt32 = 0
        return property(device, kAudioDevicePropertyTransportType, &value) ? value : nil
    }

    private static func uid(_ device: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard withUnsafeMutablePointer(to: &value, {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) == noErr
        }) else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
