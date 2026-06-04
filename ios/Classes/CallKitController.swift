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

class CallKitController : NSObject, AVAudioPlayerDelegate {
    private struct CallAudioRequest {
        let uuid: UUID
        let url: URL
        let bearerToken: String
    }

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
    private var pendingCallAudioRequest: CallAudioRequest?
    private var activeCallAudioUUID: UUID?
    private var callAudioPlayer: AVAudioPlayer?
    private var callAudioDownloadTask: URLSessionDataTask?
    private var callAudioFinishWorkItem: DispatchWorkItem?

    override init() {
        self.callController = CXCallController()
        super.init()
    }
    
    //TODO: construct configuration from flutter. pass into init over method channel

    // Current config values. `localizedName` is the call's source label shown
    // under the caller name on the CallKit screen; it's get-only after init on
    // every iOS version (the property has no setter), so the only way to change
    // it is to rebuild the whole configuration via init(localizedName:).
    // Defaults to the app name; hosts override via updateConfig(localizedName:).
    private static var cfgLocalizedName: String =
        (Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String) ?? "App"
    private static var cfgRingtone: String?
    private static var cfgIcon: String?
    private static var cfgIncludesInRecents: Bool = true

    static var providerConfiguration: CXProviderConfiguration = buildProviderConfiguration()

    /// Build a fresh CXProviderConfiguration from the current `cfg*` values.
    /// init(localizedName:) is deprecated on iOS 14+ but remains the only way
    /// to set localizedName, so we keep using it and rebuild on change.
    private static func buildProviderConfiguration() -> CXProviderConfiguration {
        let config = CXProviderConfiguration(localizedName: cfgLocalizedName)
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]

        if let ringtone = cfgRingtone {
            config.ringtoneSound = ringtone
        }
        if let icon = cfgIcon, let iconData = UIImage(named: icon)?.pngData() {
            config.iconTemplateImageData = iconData
        }
        if #available(iOS 11.0, *) {
            // Surface our calls in the iOS Phone app's Recents tab. Hosts can
            // flip this via updateConfig(includesInRecents:).
            config.includesCallsInRecents = cfgIncludesInRecents
        }
        return config
    }

    static func updateConfig(
        ringtone: String?,
        icon: String?,
        includesInRecents: Bool? = nil,
        localizedName: String? = nil
    ) {
        if let ringtone = ringtone { cfgRingtone = ringtone }
        if let icon = icon { cfgIcon = icon }
        if let includesInRecents = includesInRecents { cfgIncludesInRecents = includesInRecents }
        if let name = localizedName, !name.isEmpty { cfgLocalizedName = name }

        // localizedName can't be mutated in place — rebuild the whole config.
        providerConfiguration = buildProviderConfiguration()
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
                    self.stopCallAudio()
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
            // Use .default mode (not .voiceChat) so playback isn't capped at
            // call-volume levels — the spoken reminder needs to be audible
            // across the room. CallKit still requires .playAndRecord for the
            // active call session, so we keep that.
            //
            // No .defaultToSpeaker: when the option is set, overrideOutput
            // AudioPort(.none) just falls back to the default (speaker), so
            // the user's Speaker toggle becomes a no-op. We instead force
            // speaker explicitly in provider(didActivate:) so the initial
            // route matches phone-call UX, while leaving the toggle free to
            // swap between speaker and earpiece.
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [
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

    func playCallAudio(uuid: String, url: String, bearerToken: String) throws {
        guard let callUUID = UUID(uuidString: uuid) else {
            throw NSError(
                domain: "CallKitController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid CallKit UUID: \(uuid)"]
            )
        }

        guard let audioURL = URL(string: url) else {
            throw NSError(
                domain: "CallKitController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid call audio URL: \(url)"]
            )
        }

        let request = CallAudioRequest(
            uuid: callUUID,
            url: audioURL,
            bearerToken: bearerToken
        )

        stopCallAudio()
        pendingCallAudioRequest = request
        startPendingCallAudioIfPossible()
    }

    private func startPendingCallAudioIfPossible() {
        guard callAudioSessionActivated, let request = pendingCallAudioRequest else {
            return
        }

        pendingCallAudioRequest = nil
        activeCallAudioUUID = request.uuid

        var urlRequest = URLRequest(url: request.url)
        urlRequest.setValue("Bearer \(request.bearerToken)", forHTTPHeaderField: "Authorization")
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 30

        print("[CallKitController][playCallAudio] downloading: \(request.url)")
        callAudioDownloadTask = URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleCallAudioDownload(
                    request: request,
                    data: data,
                    response: response,
                    error: error
                )
            }
        }
        callAudioDownloadTask?.resume()
    }

    private func handleCallAudioDownload(
        request: CallAudioRequest,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        callAudioDownloadTask = nil

        guard activeCallAudioUUID == request.uuid else {
            print("[CallKitController][playCallAudio] ignoring stale audio response")
            return
        }

        if let error = error as NSError?, error.code == NSURLErrorCancelled {
            return
        }

        if let error = error {
            print("[CallKitController][playCallAudio] download failed: \(error)")
            finishActiveCallAudio(reason: "download_failed")
            return
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            print("[CallKitController][playCallAudio] bad HTTP status: \(httpResponse.statusCode)")
            finishActiveCallAudio(reason: "bad_http_status")
            return
        }

        guard let data = data, !data.isEmpty else {
            print("[CallKitController][playCallAudio] empty audio response")
            finishActiveCallAudio(reason: "empty_audio_response")
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Switch the session to `.playback` for the spoken-reminder
            // segment. `.playAndRecord` routes audio through the call-volume
            // curve, which is often much quieter than media volume even when
            // forced to speaker. `.playback` routes to speaker by default when
            // no headphones/Bluetooth route is active.
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.duckOthers]
            )
            try audioSession.setActive(true)

            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            // AVAudioPlayer.numberOfLoops counts repeats after the first play,
            // so 1 = 2 total plays.
            player.numberOfLoops = 1
            player.volume = 1.0
            player.prepareToPlay()
            callAudioPlayer = player

            if player.play() {
                scheduleCallAudioFallbackEnd(for: player, uuid: request.uuid)
                print("[CallKitController][playCallAudio] playback started")
            } else {
                print("[CallKitController][playCallAudio] playback did not start")
                finishActiveCallAudio(reason: "playback_not_started")
            }
        } catch {
            print("[CallKitController][playCallAudio] playback failed: \(error)")
            finishActiveCallAudio(reason: "playback_failed")
        }
    }

    private func scheduleCallAudioFallbackEnd(for player: AVAudioPlayer, uuid: UUID) {
        callAudioFinishWorkItem?.cancel()

        let totalPlays = max(player.numberOfLoops + 1, 1)
        let fallbackDelay = max(player.duration * Double(totalPlays) + 1.0, 1.0)
        let workItem = DispatchWorkItem { [weak self, weak player] in
            guard let self = self,
                  let player = player,
                  player === self.callAudioPlayer,
                  self.activeCallAudioUUID == uuid else {
                return
            }

            print("[CallKitController][playCallAudio] fallback end fired")
            self.finishActiveCallAudio(reason: "timeout", player: player)
        }

        callAudioFinishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay, execute: workItem)
    }

    private func finishActiveCallAudio(reason: String, player expectedPlayer: AVAudioPlayer? = nil) {
        if let expectedPlayer = expectedPlayer, expectedPlayer !== callAudioPlayer {
            return
        }

        let callUUID = activeCallAudioUUID
        callAudioFinishWorkItem?.cancel()
        callAudioFinishWorkItem = nil
        callAudioDownloadTask?.cancel()
        callAudioDownloadTask = nil
        callAudioPlayer?.stop()
        callAudioPlayer = nil
        activeCallAudioUUID = nil

        guard let callUUID = callUUID else {
            return
        }

        print("[CallKitController][playCallAudio] ending call reason: \(reason)")
        end(uuid: callUUID)
        clearCallData(uuid: callUUID.uuidString.lowercased())
    }

    private func stopCallAudio(clearPending: Bool = true) {
        callAudioDownloadTask?.cancel()
        callAudioDownloadTask = nil
        callAudioFinishWorkItem?.cancel()
        callAudioFinishWorkItem = nil
        callAudioPlayer?.stop()
        callAudioPlayer = nil
        activeCallAudioUUID = nil

        if clearPending {
            pendingCallAudioRequest = nil
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === callAudioPlayer else {
            return
        }

        print("[CallKitController][playCallAudio] playback finished successfully: \(flag)")
        finishActiveCallAudio(reason: "completed", player: player)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === callAudioPlayer else {
            return
        }

        print("[CallKitController][playCallAudio] decode error: \(String(describing: error))")
        finishActiveCallAudio(reason: "decode_error", player: player)
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

    /// Route the active CallKit session's audio to the loud speaker
    /// (true) or back to the system default route, typically the receiver
    /// (false). Applied to AVAudioSession via overrideOutputAudioPort —
    /// only meaningful while CallKit owns the active session.
    func setSpeaker(on: Bool) {
        print("[CallKitController][setSpeaker] on: \(on)")
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            print("[CallKitController][setSpeaker] failed to override audio port: \(error)")
        }
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
        stopCallAudio()
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

        // CallKit has already activated the session for us. Keep a valid
        // .playAndRecord session while waiting for the audio clip, but force
        // the initial route to speaker; the clip itself switches to .playback
        // in handleCallAudioDownload so it uses media volume.
        configureAudioSession(audioSession, active: false)
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
        } catch {
            print("[CallKitController] failed to force speaker route: \(error)")
        }
        callAudioSessionActivated = true
        sendAudioInterruptionNotification()
        completePendingReportAcceptedIfNeeded()
        emitPendingAnswerCallIfNeeded()
        startPendingCallAudioIfPossible()
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("[CallKitController] Audio session deactivated")
        callAudioSessionActivated = false
        stopCallAudio(clearPending: false)
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("[CallKitController][CXEndCallAction]")
        
        actionListener?(.endCall, action.callUUID, currentCallData)
        pendingAnswerCallUUID = nil
        callAudioSessionActivated = false
        stopCallAudio()
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
