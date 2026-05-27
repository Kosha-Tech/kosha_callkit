//
//  CallKitController.swift
//  connectycube_flutter_call_kit
//
//  Created by Tereha on 19.11.2021.
//

import Foundation
import AVFoundation
import CallKit
import UIKit

enum CallEvent : String {
    case incomingCall = "incomingCall"
    case answerCall = "answerCall"
    case endCall = "endCall"
    case setHeld = "setHeld"
    case reset = "reset"
    case startCall = "startCall"
    case setMuted = "setMuted"
    case setUnMuted = "setUnMuted"
}

enum CallEndedReason : String {
    case failed = "failed"
    case unanswered = "unanswered"
    case remoteEnded = "remoteEnded"
}

enum CallState : String {
    case pending = "pending"
    case accepted = "accepted"
    case rejected = "rejected"
    case unknown = "unknown"
}

class CallKitController : NSObject {
    // Lazy so the provider is constructed with the most recent
    // CallKitController.providerConfiguration — which Dart populates via
    // updateConfig (ringtone, icon) AFTER plugin load but BEFORE the first
    // reportIncomingCall. Eager init at plugin-load time happened before
    // Dart ran, so the provider snapshotted the default config and the
    // ringtoneSound was never applied (CallKit silently fell back to
    // system defaults). Lazy lets the first ring use the right asset.
    private lazy var provider: CXProvider = {
        let p = CXProvider(configuration: CallKitController.providerConfiguration)
        p.setDelegate(self, queue: nil)
        return p
    }()
    private let callController : CXCallController
    var actionListener : ((CallEvent, UUID, [String:Any]?)->Void)?
    var currentCallData: [String: Any] = [:]
    private var callStates: [String:CallState] = [:]
    private var callsData: [String:[String:Any]] = [:]
    private var pendingAnswerCallUUID: UUID?
    private var callAudioSessionActivated = false
    private var pendingReportAcceptedCompletions: [() -> Void] = []

    override init() {
        self.callController = CXCallController()
        super.init()
    }
    
    //TODO: construct configuration from flutter. pass into init over method channel
    static var providerConfiguration: CXProviderConfiguration = {
        let appName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as! String
        var providerConfiguration: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            providerConfiguration = CXProviderConfiguration.init()
        } else {
            providerConfiguration = CXProviderConfiguration(localizedName: appName)
        }
        
        providerConfiguration.supportsVideo = true
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.maximumCallGroups = 1;
        providerConfiguration.supportedHandleTypes = [.generic]
        
        if #available(iOS 11.0, *) {
            // Surface our calls in the iOS Phone app's Recents tab. Hosts that
            // don't want this can flip via updateConfig(includesInRecents:).
            providerConfiguration.includesCallsInRecents = true
        }

        return providerConfiguration
    }()

    static func updateConfig(
        ringtone: String?,
        icon: String?,
        includesInRecents: Bool? = nil
    ) {
        if(ringtone != nil){
            providerConfiguration.ringtoneSound = ringtone
        }

        if(icon != nil){
            let iconImage = UIImage(named: icon!)
            let iconData = iconImage?.pngData()

            providerConfiguration.iconTemplateImageData = iconData
        }

        if #available(iOS 11.0, *), let inRecents = includesInRecents {
            providerConfiguration.includesCallsInRecents = inRecents
        }
    }

    /// Push the static `providerConfiguration` onto the live CXProvider.
    /// CXProvider snapshots its configuration at init, so calling
    /// `updateConfig(...)` alone doesn't take effect — the ringtone, icon,
    /// or recents toggle wouldn't apply until next app launch otherwise.
    /// Reassigning `provider.configuration` here is the documented way to
    /// hot-swap CallKit config (iOS 14+ supports the setter directly;
    /// earlier versions discard the change but the in-memory provider was
    /// already configured at construction, so it's effectively a no-op).
    func refreshProviderConfiguration() {
        if #available(iOS 14.0, *) {
            self.provider.configuration = CallKitController.providerConfiguration
        }
    }
    
    @objc func reportIncomingCall(
        uuid: String,
        callType: Int,
        callInitiatorId: Int,
        callInitiatorName: String,
        opponents: [Int],
        userInfo: String?,
        completion: ((Error?) -> Void)?
    ) {
        print("[CallKitController][reportIncomingCall] call data: \(uuid), \(callType), \(callInitiatorId), \(callInitiatorName), \(opponents), \(userInfo ?? "nil")")
        
        let update = CXCallUpdate()
        update.localizedCallerName = callInitiatorName
        update.remoteHandle = CXHandle(type: .generic, value: uuid)
        update.hasVideo = callType == 1
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false
        
        if (self.currentCallData["session_id"] == nil || self.currentCallData["session_id"] as! String != uuid) {
            print("[CallKitController][reportIncomingCall] report new call: \(uuid)")
            
            provider.reportNewIncomingCall(with: UUID(uuidString: uuid)!, update: update) { error in
                completion?(error)
                
                if(error == nil){
                    self.callAudioSessionActivated = false
                    self.configureAudioSession(active: false)
                    
                    self.currentCallData["session_id"] = uuid
                    self.currentCallData["call_type"] = callType
                    self.currentCallData["caller_id"] = callInitiatorId
                    self.currentCallData["caller_name"] = callInitiatorName
                    self.currentCallData["call_opponents"] = opponents.map { String($0) }.joined(separator: ",")
                    self.currentCallData["user_info"] = userInfo
                    
                    self.callStates[uuid] = .pending
                    self.callsData[uuid] = self.currentCallData

                    self.actionListener?(.incomingCall, UUID(uuidString: uuid)!, self.currentCallData)
                }
            }
        } else if (self.currentCallData["session_id"] as! String == uuid) {
            print("[CallKitController][reportIncomingCall] update existing call: \(uuid)")
            
            provider.reportCall(with: UUID(uuidString: uuid)!, updated: update)
            
            completion?(nil)
        }
    }
    
    func reportOutgoingCall(uuid : UUID, finishedConnecting: Bool){
        print("[CallKitController][reportOutgoingCall] uuid: \(uuid.uuidString.lowercased()) connected: \(finishedConnecting)")
        
        if !finishedConnecting {
            self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        } else {
            self.provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        }
    }
    
    func reportCallEnded(uuid : UUID, reason: CallEndedReason){
        print("[CallKitController][reportCallEnded] uuid: \(uuid.uuidString.lowercased())")
        
        var cxReason : CXCallEndedReason
        switch reason {
        case .unanswered:
            cxReason = CXCallEndedReason.unanswered
        case .remoteEnded:
            cxReason = CXCallEndedReason.remoteEnded
        default:
            cxReason = CXCallEndedReason.failed
        }
        
        self.callStates[uuid.uuidString.lowercased()] = .rejected
        self.provider.reportCall(with: uuid, endedAt: Date.init(), reason: cxReason)
    }
    
    func getCallState(uuid: String) -> CallState {
        print("[CallKitController][getCallState] uuid: \(uuid), state: \(self.callStates[uuid.lowercased()] ?? .unknown)")
        
        return self.callStates[uuid.lowercased()] ?? .unknown
    }
    
    func setCallState(uuid: String, callState: String){
        self.callStates[uuid.lowercased()] = CallState(rawValue: callState)
    }
    
    func getCallData(uuid: String) -> [String: Any]{
        return self.callsData[uuid.lowercased()] ?? [:]
    }
    
    func clearCallData(uuid: String){
        self.callStates.removeAll()
        self.callsData.removeAll()
    }
    
    func sendAudioInterruptionNotification(){
        print("[CallKitController][sendAudioInterruptionNotification]")
        var userInfo : [AnyHashable : Any] = [:]
        let intrepEndeRaw = AVAudioSession.InterruptionType.ended.rawValue
        userInfo[AVAudioSessionInterruptionTypeKey] = intrepEndeRaw
        userInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: self, userInfo: userInfo)
    }
    
    func configureAudioSession(
        _ audioSession: AVAudioSession = AVAudioSession.sharedInstance(),
        active: Bool
    ){
        print("[CallKitController][configureAudioSession] active: \(active)")

        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [
                    .defaultToSpeaker,
                    .allowBluetooth,
                    .allowBluetoothA2DP,
                ])
            try audioSession.setPreferredSampleRate(44100.0)
            try audioSession.setPreferredIOBufferDuration(0.005)
            if active {
                try audioSession.setActive(true)
            }
        } catch {
            print(error)
        }
    }

    private func emitPendingAnswerCallIfNeeded() {
        guard let callUUID = pendingAnswerCallUUID else {
            return
        }

        pendingAnswerCallUUID = nil
        let callId = callUUID.uuidString.lowercased()
        actionListener?(.answerCall, callUUID, callsData[callId] ?? currentCallData)
    }

    private func completePendingReportAcceptedIfNeeded() {
        let completions = pendingReportAcceptedCompletions
        pendingReportAcceptedCompletions.removeAll()
        completions.forEach { $0() }
    }
}

//MARK: user actions
extension CallKitController {
    
    func end(uuid: UUID) {
        print("[CallKitController][end] uuid: \(uuid.uuidString.lowercased())")
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        
        self.callStates[uuid.uuidString.lowercased()] = .rejected
        
        requestTransaction(transaction)
    }
    
    private func requestTransaction(_ transaction: CXTransaction) {
        callController.request(transaction) { error in
            if let error = error {
                print("[CallKitController][requestTransaction] Error: \(error.localizedDescription)")
            } else {
                print("[CallKitController][requestTransaction] successfully")
            }
        }
    }
    
    func setHeld(uuid: UUID, onHold: Bool) {
        print("[CallKitController][setHeld] uuid: \(uuid.uuidString.lowercased()), onHold: \(onHold)")
        
        let setHeldCallAction = CXSetHeldCallAction(call: uuid, onHold: onHold)
        
        let transaction = CXTransaction()
        transaction.addAction(setHeldCallAction)
        
        requestTransaction(transaction)
    }
    
    func setMute(uuid: UUID, muted: Bool){
        print("[CallKitController][setMute] uuid: \(uuid.uuidString.lowercased()), muted: \(muted)")
        
        let muteCallAction = CXSetMutedCallAction(call: uuid, muted: muted);
        let transaction = CXTransaction()
        transaction.addAction(muteCallAction)
        
        requestTransaction(transaction)
    }
    
    func startCall(handle: String, videoEnabled: Bool, uuid: String? = nil) {
        print("[CallKitController][startCall] handle:\(handle), videoEnabled: \(videoEnabled) uuid: \(uuid ?? "nil")")
        
        let handle = CXHandle(type: .generic, value: handle)
        let callUUID = uuid == nil ? UUID() : UUID(uuidString: uuid!)
        let startCallAction = CXStartCallAction(call: callUUID!, handle: handle)
        startCallAction.isVideo = videoEnabled
        
        let transaction = CXTransaction(action: startCallAction)
        
        self.callStates[uuid!.lowercased()] = .accepted
        
        requestTransaction(transaction);
    }
    
    func answerCall(uuid: String, completion: (() -> Void)? = nil) {
        print("[CallKitController][answerCall] uuid: \(uuid)")

        if let completion = completion {
            if self.callStates[uuid.lowercased()] == .accepted && callAudioSessionActivated {
                completion()
            } else {
                pendingReportAcceptedCompletions.append(completion)
            }
        }

        if self.callStates[uuid.lowercased()] == .accepted {
            print("[CallKitController][answerCall] already accepted: \(uuid)")
            return
        }
        
        let callUUID = UUID(uuidString: uuid)
        let answerCallAction = CXAnswerCallAction(call: callUUID!)
        let transaction = CXTransaction(action: answerCallAction)
        
        self.callStates[uuid.lowercased()] = .accepted
        
        requestTransaction(transaction);
    }
}

//MARK: System notifications
extension CallKitController: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        pendingAnswerCallUUID = nil
        callAudioSessionActivated = false
        completePendingReportAcceptedIfNeeded()
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("[CallKitController][CXAnswerCallAction] callUUID: \(action.callUUID.uuidString.lowercased())")
        
        configureAudioSession(active: false)
        pendingAnswerCallUUID = action.callUUID
        callStates[action.callUUID.uuidString.lowercased()] = .accepted
        
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("[CallKitController] Audio session activated")

        // CallKit has already activated the session for us — calling
        // setActive(true) again was a no-op AND the existing config
        // (.playAndRecord + .videoChat without .defaultToSpeaker) routed
        // audio to the earpiece, making any media playback during the
        // call effectively silent on the loudspeaker.
        //
        // Reconfigure for spoken-reminder playback: keep .playAndRecord
        // (CallKit requires the session stay valid for a voice call) but
        // switch to .spokenAudio mode and force .defaultToSpeaker so the
        // host app's AVPlayer (just_audio in our case) is audible.
        configureAudioSession(audioSession, active: false)
        callAudioSessionActivated = true
        sendAudioInterruptionNotification()
        completePendingReportAcceptedIfNeeded()
        emitPendingAnswerCallIfNeeded()
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("[CallKitController] Audio session deactivated")
        callAudioSessionActivated = false
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("[CallKitController][CXEndCallAction]")
        
        actionListener?(.endCall, action.callUUID, currentCallData)
        pendingAnswerCallUUID = nil
        callAudioSessionActivated = false
        completePendingReportAcceptedIfNeeded()
        callStates[action.callUUID.uuidString.lowercased()] = .rejected
        
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        print("[CallKitController][CXSetHeldCallAction] callUUID: \(action.callUUID.uuidString.lowercased())")
        
        actionListener?(.setHeld, action.callUUID, ["isOnHold": action.isOnHold])
        
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        print("[CallKitController][CXSetMutedCallAction] callUUID: \(action.callUUID.uuidString.lowercased())")
        
        if (action.isMuted){
            actionListener?(.setMuted, action.callUUID, currentCallData)
        } else {
            actionListener?(.setUnMuted, action.callUUID, currentCallData)
        }
        
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("[CallKitController][CXStartCallAction]: callUUID: \(action.callUUID.uuidString.lowercased())")
        
        actionListener?(.startCall, action.callUUID, currentCallData)
        callStates[action.callUUID.uuidString.lowercased()] = .accepted
        configureAudioSession(active: false)
        
        action.fulfill()
    }
}
