import Foundation
import AVFoundation
import MapboxDirections
import MapboxCoreNavigation

extension NSAttributedString {
    public func pronounced(_ pronunciation: String) -> NSAttributedString {
        let phoneticWords = pronunciation.components(separatedBy: " ")
        let phoneticString = NSMutableAttributedString()
        for (word, phoneticWord) in zip(string.components(separatedBy: " "), phoneticWords) {
            // AVSpeechSynthesizer doesn’t recognize some common IPA symbols.
            let phoneticWord = phoneticWord.byReplacing([("ɡ", "g"), ("ɹ", "r")])
            if phoneticString.length > 0 {
                phoneticString.append(NSAttributedString(string: " "))
            }
            phoneticString.append(NSAttributedString(string: word, attributes: [
                NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute): phoneticWord
            ]))
        }
        return phoneticString
    }
}

extension SpokenInstruction {
    func attributedText(for legProgress: RouteLegProgress) -> NSAttributedString {
        let attributedText = NSMutableAttributedString(string: text)
        if let step = legProgress.upcomingStep,
            let name = step.names?.first,
            let phoneticName = step.phoneticNames?.first {
            let nameRange = attributedText.mutableString.range(of: name)
            if (nameRange.location != NSNotFound) {
                attributedText.replaceCharacters(in: nameRange, with: NSAttributedString(string: name).pronounced(phoneticName))
            }
        }
        if let step = legProgress.followOnStep,
            let name = step.names?.first,
            let phoneticName = step.phoneticNames?.first {
            let nameRange = attributedText.mutableString.range(of: name)
            if (nameRange.location != NSNotFound) {
                attributedText.replaceCharacters(in: nameRange, with: NSAttributedString(string: name).pronounced(phoneticName))
            }
        }
        return attributedText
    }
}

/**
 A route voice controller monitors turn-by-turn navigation events and triggers playing spoken instructions as audio using the Speech Synthesis framework, also known as VoiceOver.
 
 You initialize a voice controller using a `NavigationService` instance. The voice controller observes when the navigation service hints that the user has passed a _spoken instruction point_ and responds by calling it's `speechSynthesizer` to handle the vocalization.
 
 If you want to use your own custom `SpeechSynthesizing` implementation - also pass it during initialization. If no implementation is provided - `MultiplexedSpeechSynthesizer` will be used by default.
 
 You can also subclass `RouteVoiceController` to implement you own mechanism of monitoring navgiation events and calling `speechSynthesizer`.
 */
open class RouteVoiceController: NSObject, AVSpeechSynthesizerDelegate {
    typealias AudioControlFailureHandler = (SpeechError) -> Void
    
    /**
     `SpeechSynthesizing` implementation, used to vocalize the spoken instructions. Defaults to `MultiplexedSpeechSynthesizer`
     */
    public let speechSynthesizer: SpeechSynthesizing
    /**
     If true, a noise indicating the user is going to be rerouted will play prior to rerouting.
     */
    public var playRerouteSound = true
    
    /**
     Sound to play prior to reroute. Inherits volume level from `volume`.
     */
    public var rerouteSoundPlayer: AVAudioPlayer = try! AVAudioPlayer(data: NSDataAsset(name: "reroute-sound", bundle: .mapboxNavigation)!.data, fileTypeHint: AVFileType.mp3.rawValue)
    
    /**
     Delegate used for getting metadata information about route vocalization
     */
    public weak var routeVoiceControllerDelegate: RouteVoiceControllerDelegate?
    
    var lastSpokenInstruction: SpokenInstruction?
    
    /**
     Default initializer for `RouteVoiceController`.
     */
    public init(navigationService: NavigationService, speechSynthesizer: SpeechSynthesizing? = nil) {
        self.speechSynthesizer = speechSynthesizer ?? MultiplexedSpeechSynthesizer()
        
        super.init()

        verifyBackgroundAudio()

        observeNotifications(by: navigationService)
    }
    
    @available(*, unavailable, message: "Use init(navigationService:) instead.")
    public override init() {
        fatalError()
    }

    private func verifyBackgroundAudio() {
        guard UIApplication.shared.isKind(of: UIApplication.self) else {
            return
        }

        if !Bundle.main.backgroundModes.contains("audio") {
            assert(false, "This application’s Info.plist file must include “audio” in UIBackgroundModes. This background mode is used for spoken instructions while the application is in the background.")
        }
    }

    deinit {
        suspendNotifications()
    }
    
    func observeNotifications(by service: NavigationService) {
        NotificationCenter.default.addObserver(self, selector: #selector(didPassSpokenInstructionPoint(notification:)), name: .routeControllerDidPassSpokenInstructionPoint, object: service.router)
        NotificationCenter.default.addObserver(self, selector: #selector(pauseSpeechAndPlayReroutingDing(notification:)), name: .routeControllerWillReroute, object: service.router)
        NotificationCenter.default.addObserver(self, selector: #selector(didReroute(notification:)), name: .routeControllerDidReroute, object: service.router)
        NotificationCenter.default.addObserver(self, selector: #selector(didUpdateSettings(notification:)), name: .navigationSettingsDidChange, object: nil)
    }
    
    func suspendNotifications() {
        NotificationCenter.default.removeObserver(self, name: .routeControllerDidPassSpokenInstructionPoint, object: nil)
        NotificationCenter.default.removeObserver(self, name: .routeControllerWillReroute, object: nil)
        NotificationCenter.default.removeObserver(self, name: .routeControllerDidReroute, object: nil)
        NotificationCenter.default.removeObserver(self, name: .navigationSettingsDidChange, object: nil)
    }
    
    @objc func didUpdateSettings(notification: NSNotification) {
        if let isMuted = notification.userInfo?[NavigationSettings.StoredProperty.voiceMuted.key] as? Bool {
            speechSynthesizer.muted = isMuted
        }
        if let volume = notification.userInfo?[NavigationSettings.StoredProperty.voiceVolume.key] as? Float {
            speechSynthesizer.volume = volume
        }
    }
    
    @objc func didReroute(notification: NSNotification) {
        // Play reroute sound when a faster route is found
        if notification.userInfo?[LegacyRouteController.NotificationUserInfoKey.isProactiveKey] as! Bool {
            pauseSpeechAndPlayReroutingDing(notification: notification)
        }
    }
    
    @objc func pauseSpeechAndPlayReroutingDing(notification: NSNotification) {
        guard playRerouteSound && !NavigationSettings.shared.voiceMuted else {
            return
        }
        
        speechSynthesizer.stopSpeaking()
        
        safeMixAudio(instruction: nil) {
            routeVoiceControllerDelegate?.routeVoiceController(self, encountered: $0)
        }
        
        rerouteSoundPlayer.play()
    }
    
    func safeMixAudio(instruction: SpokenInstruction?, failure: AudioControlFailureHandler) {
        do {
            try tryMixAudio()
        } catch {
            let wrapped = SpeechError.unableToControlAudio(instruction: instruction, action: .mix, underlying: error)
            failure(wrapped)
            return
        }
    }
    
    func tryMixAudio() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.ambient, mode: audioSession.mode)
        try audioSession.setActive(true)
    }
        
    private var previouslySpokenInstructionText: String?
    @objc open func didPassSpokenInstructionPoint(notification: NSNotification) {
        let routeProgress = notification.userInfo![LegacyRouteController.NotificationUserInfoKey.routeProgressKey] as! RouteProgress
        
        speechSynthesizer.locale = routeProgress.routeOptions.locale
        let locale = routeProgress.route.speechLocale

        speechSynthesizer.prepareIncomingSpokenInstructions(routeProgress.currentLegProgress.currentStepProgress.remainingSpokenInstructions ?? [], locale: locale)
        
        guard let instruction = routeProgress.currentLegProgress.currentStepProgress.currentSpokenInstruction,
              previouslySpokenInstructionText != instruction.text else { return }
        previouslySpokenInstructionText = instruction.text
        if NavigationSettings.shared.voiceMuted { return }
        
        speechSynthesizer.speak(instruction,
                                during: routeProgress.currentLegProgress,
                                locale: locale)
    }
}

/**
 The `RouteVoiceControllerDelegate` protocol defines methods that allow an object to respond to significant events related to route vocalization
 */
public protocol RouteVoiceControllerDelegate: class, UnimplementedLogging {
    /**
     Called when the route voice controller reports an error
     
     - parameter routeVoiceController: The route voice controller that experienced the failure.
     - parameter error: An error explaining the failure and its cause.
     */
    func routeVoiceController(_ routeVoiceController: RouteVoiceController, encountered error: SpeechError)
}

public extension RouteVoiceControllerDelegate {
    /**
     `UnimplementedLogging` prints a warning to standard output the first time this method is called.
     */
    func routeVoiceController(_ routeVoiceController: RouteVoiceController, encountered error: SpeechError) {
        logUnimplemented(protocolType: RouteVoiceControllerDelegate.self, level: .debug)
    }
}
