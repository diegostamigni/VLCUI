import Combine
import Foundation
import MediaPlayer

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
import VLCKit
#elseif os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

// TODO: Cleanup constructPlaybackInformation

public class UIVLCVideoPlayerView: _PlatformView {

    private lazy var videoContentView = makeVideoContentView()

    private var startConfiguration: VLCVideoPlayer.Configuration
    private let eventSubject: CurrentValueSubject<VLCVideoPlayer.Event?, Never>
    private let onTicksUpdated: (Int32, VLCVideoPlayer.PlaybackInformation) -> Void
    private let onStateUpdated: (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void
    private let logger: VLCVideoPlayerLogger
    private var currentMediaPlayer: VLCMediaPlayer?

    private var hasSetDefaultConfiguration: Bool = false
    private var lastPlayerTicks: Int32 = 0
    private var lastPlayerState: VLCMediaPlayerState = .opening
    private var cancellables = Set<AnyCancellable>()

    private var aspectFillScale: CGFloat {
        guard let currentMediaPlayer = currentMediaPlayer else { return 1 }
        let videoSize = currentMediaPlayer.videoSize
        let fillSize = CGSize.aspectFill(aspectRatio: videoSize, minimumSize: videoContentView.bounds.size)
        return fillSize.scale(other: videoContentView.bounds.size)
    }

    init(
        configuration: VLCVideoPlayer.Configuration,
        eventSubject: CurrentValueSubject<VLCVideoPlayer.Event?, Never>,
        onTicksUpdated: @escaping (Int32, VLCVideoPlayer.PlaybackInformation) -> Void,
        onStateUpdated: @escaping (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void,
        logger: VLCVideoPlayerLogger
    ) {
        self.startConfiguration = configuration
        self.eventSubject = eventSubject
        self.onTicksUpdated = onTicksUpdated
        self.onStateUpdated = onStateUpdated
        self.logger = logger
        super.init(frame: .zero)

        #if os(macOS)
        layer?.backgroundColor = .clear
        #else
        backgroundColor = .clear
        #endif

        setupVideoContentView()
        setupVLCMediaPlayer(with: configuration)
        setupEventSubjectListener()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupVideoContentView() {
        addSubview(videoContentView)

        NSLayoutConstraint.activate([
            videoContentView.topAnchor.constraint(equalTo: topAnchor),
            videoContentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoContentView.leftAnchor.constraint(equalTo: leftAnchor),
            videoContentView.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    private func setupVLCMediaPlayer(with configuration: VLCVideoPlayer.Configuration) {
        self.currentMediaPlayer?.stop()
        self.currentMediaPlayer = nil

        let media = VLCMedia(url: configuration.url)
        media.addOptions(configuration.options)

        let newMediaPlayer = VLCMediaPlayer()
        newMediaPlayer.media = media
        newMediaPlayer.drawable = videoContentView
        newMediaPlayer.delegate = self

        newMediaPlayer.libraryInstance.debugLogging = configuration.isLogging
        newMediaPlayer.libraryInstance.debugLoggingLevel = 3
        newMediaPlayer.libraryInstance.debugLoggingTarget = self

        for child in configuration.playbackChildren {
            newMediaPlayer.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
        }

        self.startConfiguration = configuration
        self.currentMediaPlayer = newMediaPlayer
        self.hasSetDefaultConfiguration = false
        self.lastPlayerTicks = 0
        self.lastPlayerState = .opening

        if configuration.autoPlay {
            newMediaPlayer.play()
        }
    }

    private func makeVideoContentView() -> _PlatformView {
        let view = _PlatformView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false

        #if os(macOS)
        view.layer?.backgroundColor = .black
        #else
        view.backgroundColor = .black
        #endif
        return view
    }
}

// MARK: Event Listener

public extension UIVLCVideoPlayerView {

    func setupEventSubjectListener() {
        eventSubject.sink { event in
            guard let event = event,
                  let currentMediaPlayer = self.currentMediaPlayer,
                  let media = currentMediaPlayer.media else { return }
            switch event {
            case .play:
                currentMediaPlayer.play()
            case .pause:
                currentMediaPlayer.pause()
            case .stop:
                currentMediaPlayer.stop()
            case .cancel:
                currentMediaPlayer.stop()
                self.cancellables.forEach { $0.cancel() }
            case let .jumpForward(interval):
                currentMediaPlayer.jumpForward(interval)
            case let .jumpBackward(interval):
                currentMediaPlayer.jumpBackward(interval)
            case .gotoNextFrame:
                currentMediaPlayer.gotoNextFrame()
            case let .setSubtitleTrack(track):
                let newTrackIndex = currentMediaPlayer.subtitleTrackIndex(from: track)
                currentMediaPlayer.currentVideoSubTitleIndex = newTrackIndex
            case let .setAudioTrack(track):
                let newTrackIndex = currentMediaPlayer.audioTrackIndex(from: track)
                currentMediaPlayer.currentAudioTrackIndex = newTrackIndex
            case let .setSubtitleDelay(delay):
                let delay = Int(delay.asTicks) * 1000
                currentMediaPlayer.currentVideoSubTitleDelay = delay
            case let .setAudioDelay(delay):
                let delay = Int(delay.asTicks) * 1000
                currentMediaPlayer.currentAudioPlaybackDelay = delay
            case let .fastForward(speed):
                let newSpeed = currentMediaPlayer.fastForwardSpeed(from: speed)
                currentMediaPlayer.fastForward(atRate: newSpeed)
            case let .aspectFill(fill):
                guard fill >= 0 && fill <= 1 else { return }
                let scale = 1 + CGFloat(fill) * (self.aspectFillScale - 1)
                self.videoContentView.scale(x: scale, y: scale)
            case let .setTime(time):
                guard time.asTicks >= 0 && time.asTicks <= media.length.intValue else { return }
                currentMediaPlayer.time = VLCTime(int: time.asTicks)
            case let .setSubtitleSize(size):
                currentMediaPlayer.setSubtitleSize(size)
            case let .setSubtitleFont(font):
                currentMediaPlayer.setSubtitleFont(font)
            case let .setSubtitleColor(color):
                currentMediaPlayer.setSubtitleColor(color)
            case let .addPlaybackChild(child):
                currentMediaPlayer.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
            case let .playNewMedia(newConfiguration):
                self.setupVLCMediaPlayer(with: newConfiguration)
            }
        }
        .store(in: &cancellables)
    }
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    private func constructPlaybackInformation(player: VLCMediaPlayer, media: VLCMedia) -> VLCVideoPlayer.PlaybackInformation {

        let subtitleIndexes = player.videoSubTitlesIndexes as! [Int32]
        let subtitleNames = player.videoSubTitlesNames as! [String]

        let audioIndexes = player.audioTrackIndexes as! [Int32]
        let audioNames = player.audioTrackNames as! [String]

        let zippedSubtitleTracks = Dictionary(uniqueKeysWithValues: zip(subtitleIndexes, subtitleNames))
        let zippedAudioTracks = Dictionary(uniqueKeysWithValues: zip(audioIndexes, audioNames))

        let currentSubtitleTrack: MediaTrack
        let currentAudioTrack: MediaTrack

        if let currentValidSubtitleTrack = zippedSubtitleTracks[player.currentVideoSubTitleIndex] {
            currentSubtitleTrack = (player.currentVideoSubTitleIndex, currentValidSubtitleTrack)
        } else {
            currentSubtitleTrack = (index: -1, title: "Disable")
        }

        if let currentValidAudioTrack = zippedAudioTracks[player.currentAudioTrackIndex] {
            currentAudioTrack = (player.currentAudioTrackIndex, currentValidAudioTrack)
        } else {
            currentAudioTrack = (index: -1, title: "Disable")
        }

        return VLCVideoPlayer.PlaybackInformation(
            startConfiguration: startConfiguration,
            position: player.position,
            length: media.length.intValue,
            isSeekable: player.isSeekable,
            playbackRate: player.rate,
            currentSubtitleTrack: currentSubtitleTrack,
            currentAudioTrack: currentAudioTrack,
            subtitleTracks: zippedSubtitleTracks,
            audioTracks: zippedAudioTracks,
            stats: media.stats ?? [:]
        )
    }

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let player = aNotification.object as! VLCMediaPlayer
        let currentTicks = player.time.intValue
        let playbackInformation = constructPlaybackInformation(player: player, media: player.media!)

        onTicksUpdated(currentTicks, playbackInformation)

        // Set playing state
        if lastPlayerState != .playing,
           abs(currentTicks - lastPlayerTicks) >= 200
        {
            onStateUpdated(.playing, playbackInformation)
            lastPlayerState = .playing
            lastPlayerTicks = currentTicks

            if !hasSetDefaultConfiguration {
                setStartConfiguration(with: player, from: startConfiguration)
                hasSetDefaultConfiguration = true
            }
        }

        // Replay
        if startConfiguration.replay,
           lastPlayerState == .playing,
           abs(player.media!.length.intValue - currentTicks) <= 500
        {
            startConfiguration.autoPlay = true
            startConfiguration.startTime = .ticks(0)
            setupVLCMediaPlayer(with: startConfiguration)
        }
    }

    public func mediaPlayerStateChanged(_ aNotification: Notification) {
        let player = aNotification.object as! VLCMediaPlayer
        guard player.state != .playing, player.state != lastPlayerState else { return }

        let wrappedState = VLCVideoPlayer.State(rawValue: player.state.rawValue) ?? .error
        let playbackInformation = constructPlaybackInformation(player: player, media: player.media!)

        onStateUpdated(wrappedState, playbackInformation)
        lastPlayerState = player.state
    }

    private func setStartConfiguration(with player: VLCMediaPlayer, from configuration: VLCVideoPlayer.Configuration) {

        player.time = VLCTime(int: configuration.startTime.asTicks)

        let defaultPlayerSpeed = player.fastForwardSpeed(from: configuration.playbackSpeed)
        player.fastForward(atRate: defaultPlayerSpeed)

        if configuration.aspectFill {
            videoContentView.scale(x: aspectFillScale, y: aspectFillScale)
        } else {
            videoContentView.apply(transform: .identity)
        }

        let defaultSubtitleTrackIndex = player.subtitleTrackIndex(from: configuration.subtitleIndex)
        player.currentVideoSubTitleIndex = defaultSubtitleTrackIndex

        let defaultAudioTrackIndex = player.audioTrackIndex(from: configuration.audioIndex)
        player.currentAudioTrackIndex = defaultAudioTrackIndex

        player.setSubtitleSize(configuration.subtitleSize)
        player.setSubtitleFont(configuration.subtitleFont)
        player.setSubtitleColor(configuration.subtitleColor)
    }
}

// MARK: VLCLibraryLogReceiverProtocol

extension UIVLCVideoPlayerView: VLCLibraryLogReceiverProtocol {

    public func handleMessage(_ message: String, debugLevel level: Int32) {
        guard level >= startConfiguration.loggingLevel.rawValue else { return }
        let level = VLCVideoPlayer.LoggingLevel(rawValue: level) ?? .info
        self.logger.vlcVideoPlayer(didLog: message, at: level)
    }
}
