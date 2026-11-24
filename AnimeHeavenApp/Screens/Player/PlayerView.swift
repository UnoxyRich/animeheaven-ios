import AVFoundation
import SwiftUI
import UIKit
import OSLog
import AnimeHeavenCore

private enum DragGestureKind {
    case brightness
    case volume
}

private struct DragHudIndicator: Equatable {
    let kind: DragGestureKind
    let percent: Int
}

struct PlayerView: View {
    let presentation: PlayerPresentation
    let container: AppContainer
    let onDismiss: () -> Void

    @Environment(\.ahPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var modelStorage: ViewModelStorage<PlayerViewModel>
    private var viewModel: PlayerViewModel { modelStorage.value }
    @State private var player = AVPlayer()
    @State private var progress = PlayerProgressModel()
    @State private var pipCoordinator = PipCoordinator()
    @State private var nowPlaying = NowPlayingBridge()

    @State private var isPlaying = false
    @State private var isBuffering = true
    @State private var isInPipMode = false
    @State private var hudVisible = true
    @State private var hudNonce = 0
    @State private var isLocked = false
    @State private var showUnlockHint = false
    @State private var isScrubbing = false

    @State private var resizeMode: VideoResizeMode = .fit
    @State private var playbackRate: Float = 1.0
    @State private var isLandscape: Bool
    @State private var seekFeedback: String?
    @State private var seekFeedbackNonce = 0
    @State private var dragIndicator: DragHudIndicator?
    @State private var activeSkipSegment: SkipSegment?
    @State private var handledSkipTypes: Set<SkipSegmentType> = []
    @State private var showUpNextOverlay = false
    @State private var upNextSecondsLeft = 0

    @State private var timeObserverToken: Any?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var timeControlObservation: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?
    @State private var lastPersistedAtMs: Int64 = 0
    @State private var activeDragKind: DragGestureKind?
    @State private var dragStartBrightness: CGFloat = 0.5
    @State private var dragStartVolume: Float = 0.5
    @State private var isCleanedUp = false
    @State private var hasAudioSession = false
    @State private var brightnessScreen: UIScreen?
    @State private var originalBrightness: CGFloat?
    @State private var unlockHintTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "me.animeheaven.ios", category: "Playback")

    private let speedOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init(presentation: PlayerPresentation, container: AppContainer, onDismiss: @escaping () -> Void) {
        self.presentation = presentation
        self.container = container
        self.onDismiss = onDismiss
        _isLandscape = State(initialValue: container.settingsStore.autoLandscapePlayer)
        _modelStorage = StateObject(wrappedValue: ViewModelStorage(PlayerViewModel(
            animeId: presentation.animeId,
            animeTitle: presentation.animeTitle,
            coverUrl: presentation.coverUrl,
            repository: container.repository,
            settingsStore: container.settingsStore,
            skipTimesClient: container.skipTimesClient,
            chunkBooster: container.chunkBooster,
            proxyServer: container.proxyServer,
            networkPolicy: container.networkPolicy,
            preloader: container.preloader
        )))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AVPlayerLayerView(
                player: player,
                resizeMode: resizeMode,
                pipCoordinator: pipCoordinator
            )
            .ignoresSafeArea()

            if !isInPipMode {
                gestureOverlay
            }

            if !isInPipMode && (viewModel.isLoading || (isBuffering && viewModel.errorMessage == nil)) {
                ProgressView()
                    .tint(palette.crimson)
                    .scaleEffect(1.5)
            }

            if !isInPipMode, let indicator = dragIndicator {
                HStack(spacing: 8) {
                    Image(systemName: indicator.kind == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                    Text("\(indicator.percent)%")
                        .monospacedDigit()
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.75), in: Capsule())
            } else if !isInPipMode, let feedback = seekFeedback {
                Text(feedback)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75), in: Capsule())
            }

            if !isInPipMode, let err = viewModel.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(palette.crimson)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    HStack(spacing: 12) {
                        Button("Retry") {
                            if let epKey = viewModel.stream?.episodeKey {
                                viewModel.loadEpisode(episodeKey: epKey, forceRefreshGate: true)
                            } else {
                                viewModel.loadEpisode(episodeKey: presentation.episodeKey, forceRefreshGate: true)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(palette.crimson, in: Capsule())
                        .foregroundStyle(.white)

                        Button("Close") { exitPlayer() }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }

            if !isInPipMode && isLocked && showUnlockHint {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            isLocked = false
                            showUnlockHint = false
                            hudVisible = true
                            hudNonce += 1
                        } label: {
                            Label("Unlock", systemImage: "lock.open.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.78), in: Capsule())
                        }
                        .padding(20)
                    }
                    Spacer()
                }
            }

            if !isInPipMode && !isLocked && hudVisible && !showUpNextOverlay && viewModel.errorMessage == nil {
                hudOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }

            if !isInPipMode && !isLocked && !hudVisible && !showUpNextOverlay,
               let segment = activeSkipSegment {
                skipPromptOverlay(segment: segment)
            }

            if !isInPipMode && showUpNextOverlay, let nextKey = viewModel.stream?.nextEpisodeKey {
                upNextOverlay(nextEpisodeKey: nextKey)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            isCleanedUp = false
            UIApplication.shared.isIdleTimerDisabled = true
            if isLandscape {
                OrientationManager.shared.lockLandscape()
            }
            configurePlayerObservers()
        }
        .onDisappear {
            cleanupPlayer()
        }
        .task(id: presentation.episodeKey) {
            viewModel.loadEpisode(episodeKey: presentation.episodeKey)
        }
        .onChange(of: viewModel.playbackURL, initial: true) { _, newURL in
            guard !isCleanedUp else { return }
            if let newURL {
                loadIntoAVPlayer(url: newURL)
            } else {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
        }
        .onChange(of: isLandscape) { _, landscape in
            if landscape {
                OrientationManager.shared.lockLandscape()
            } else {
                OrientationManager.shared.requestPortrait()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && !isInPipMode {
                persistCurrentProgress()
            }
        }
        .task(id: hudNonce) {
            guard hudVisible && isPlaying && !isScrubbing else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && isPlaying && !isScrubbing {
                withAnimation { hudVisible = false }
            }
        }
        .task(id: seekFeedbackNonce) {
            guard seekFeedback != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled {
                seekFeedback = nil
            }
        }
        .task(id: showUpNextOverlay) {
            guard showUpNextOverlay, let nextKey = viewModel.stream?.nextEpisodeKey else { return }
            while upNextSecondsLeft > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                upNextSecondsLeft -= 1
            }
            if !Task.isCancelled && showUpNextOverlay {
                switchToEpisode(nextKey)
            }
        }
    }

    // MARK: - Gesture Layer

    private var gestureOverlay: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    if isLocked {
                        flashUnlockHint()
                        return
                    }
                    let w = max(1, geo.size.width)
                    let step = viewModel.settingsStore.doubleTapSeekSeconds
                    if location.x < w * 0.38 {
                        seekBy(deltaMs: -Int64(step) * 1000, label: "-\(step)s")
                    } else if location.x > w * 0.62 {
                        seekBy(deltaMs: Int64(step) * 1000, label: "+\(step)s")
                    } else {
                        togglePlayPause()
                    }
                }
                .onTapGesture(count: 1) {
                    if isLocked {
                        flashUnlockHint()
                    } else {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            hudVisible.toggle()
                        }
                        if hudVisible { hudNonce += 1 }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            guard !isLocked else { return }
                            if activeDragKind == nil {
                                // Only engage vertical brightness/volume drag when gesture is predominantly vertical
                                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                                let isLeft = value.startLocation.x < geo.size.width / 2
                                activeDragKind = isLeft ? .brightness : .volume
                                if brightnessScreen == nil {
                                    brightnessScreen = UIApplication.shared.connectedScenes
                                        .compactMap { $0 as? UIWindowScene }
                                        .first { $0.windows.contains(where: \.isKeyWindow) }?.screen
                                    originalBrightness = brightnessScreen?.brightness
                                }
                                dragStartBrightness = brightnessScreen?.brightness ?? 0.5
                                dragStartVolume = player.volume
                            }
                            let delta = -value.translation.height / max(220, geo.size.height * 0.7)
                            switch activeDragKind {
                            case .brightness:
                                let next = min(1.0, max(0.03, dragStartBrightness + delta))
                                brightnessScreen?.brightness = next
                                dragIndicator = DragHudIndicator(kind: .brightness, percent: Int((next * 100).rounded()))
                            case .volume:
                                let next = min(1.0, max(0.0, dragStartVolume + Float(delta)))
                                player.volume = next
                                dragIndicator = DragHudIndicator(kind: .volume, percent: Int((next * 100).rounded()))
                            case nil:
                                break
                            }
                        }
                        .onEnded { _ in
                            activeDragKind = nil
                            dragIndicator = nil
                        }
                )
        }
    }

    // MARK: - HUD Overlay

    private var hudOverlay: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                Button { exitPlayer() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.55), in: Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.animeTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let epLabel = viewModel.stream?.episodeLabel, !epLabel.isEmpty {
                        Text(epLabel)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if viewModel.mirrorState.mirrorCount > 1 {
                    Button {
                        hudNonce += 1
                        viewModel.cycleMirrorManually(currentPositionMs: progress.positionMs)
                    } label: {
                        Text(viewModel.mirrorState.displayLabel)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                }

                Button {
                    hudNonce += 1
                    cycleSpeed()
                } label: {
                    Text(String(format: "%.2gx", playbackRate))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }

                Button {
                    hudNonce += 1
                    resizeMode = resizeMode.next()
                } label: {
                    Text(resizeMode.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }

                if pipCoordinator.isPipSupported {
                    Button {
                        pipCoordinator.startPip()
                    } label: {
                        Image(systemName: "pip.enter")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.18), in: Circle())
                    }
                }

                Button {
                    hudNonce += 1
                    isLandscape.toggle()
                } label: {
                    Image(systemName: "rectangle.portrait.rotate")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.18), in: Circle())
                }

                Button {
                    isLocked = true
                    hudVisible = false
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.18), in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .background(
                LinearGradient(colors: [Color.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
            )

            Spacer()

            // Center Transport Controls
            HStack(spacing: 36) {
                Button {
                    let step = viewModel.settingsStore.doubleTapSeekSeconds
                    seekBy(deltaMs: -Int64(step) * 1000, label: "-\(step)s")
                } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.45), in: Circle())
                }

                Button { togglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(palette.crimson, in: Circle())
                }

                Button {
                    let step = viewModel.settingsStore.doubleTapSeekSeconds
                    seekBy(deltaMs: Int64(step) * 1000, label: "+\(step)s")
                } label: {
                    Image(systemName: "goforward")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
            }

            Spacer()

            // Bottom Scrubber + Episode Nav
            VStack(spacing: 10) {
                InteractiveSeekBar(
                    progress: progress,
                    accentColor: palette.crimson,
                    onSeekCommitted: { targetMs in
                        seekTo(ms: targetMs)
                        hudNonce += 1
                    },
                    onScrubbingChanged: { scrubbing in
                        isScrubbing = scrubbing
                        if !scrubbing { hudNonce += 1 }
                    }
                )

                HStack {
                    if let prevKey = viewModel.stream?.prevEpisodeKey {
                        Button {
                            switchToEpisode(prevKey)
                        } label: {
                            Label("Previous", systemImage: "backward.end.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.18), in: Capsule())
                        }
                    }

                    Spacer()

                    Button {
                        let jump = Int64(viewModel.settingsStore.skipOpSeconds) * 1000
                        seekBy(deltaMs: jump, label: "+\(viewModel.settingsStore.skipOpSeconds)s")
                    } label: {
                        Label("Skip +\(viewModel.settingsStore.skipOpSeconds)s", systemImage: "forward.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }

                    if let nextKey = viewModel.stream?.nextEpisodeKey {
                        Button {
                            switchToEpisode(nextKey)
                        } label: {
                            Label("Next Ep", systemImage: "forward.end.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(palette.crimson, in: Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(
                LinearGradient(colors: [.clear, Color.black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
            )
        }
    }

    @ViewBuilder
    private func skipPromptOverlay(segment: SkipSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    executeSkip(segment: segment)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "forward.fill")
                        Text(segment.type == .op ? "Skip Opening" : "Skip Ending")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(palette.crimson, in: Capsule())
                    .shadow(radius: 8)
                }
                .padding(.trailing, 24)
                .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private func upNextOverlay(nextEpisodeKey: String) -> some View {
        VStack(spacing: 14) {
            Text("Up Next in \(upNextSecondsLeft)s")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            if let label = viewModel.stream?.nextEpisodeLabel {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 12) {
                Button("Play Now") {
                    switchToEpisode(nextEpisodeKey)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(palette.crimson, in: Capsule())
                .foregroundStyle(.white)

                Button("Cancel") {
                    showUpNextOverlay = false
                    hudVisible = true
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.2), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(24)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - AVPlayer Wiring

    private func loadIntoAVPlayer(url: URL) {
        isBuffering = true
        showUpNextOverlay = false
        activeSkipSegment = nil
        handledSkipTypes.removeAll()

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 25

        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { observedItem, _ in
            Task { @MainActor in
                guard !isCleanedUp, player.currentItem === observedItem else { return }
                switch observedItem.status {
                case .readyToPlay:
                    isBuffering = false
                    let durSec = observedItem.duration.seconds
                    let durMs = durSec.isFinite && durSec > 0 ? Int64(durSec * 1000) : 0
                    if durMs > 0 { progress.durationMs = durMs }
                    if viewModel.initialResumePositionMs > 0 {
                        let target = CMTime(value: viewModel.initialResumePositionMs, timescale: 1000)
                        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    guard !isCleanedUp, player.currentItem === observedItem else { return }
                    startAudioSession()
                    player.playImmediately(atRate: playbackRate)
                    viewModel.onPlaybackStarted(durationMs: durMs)
                case .failed:
                    isBuffering = false
                    viewModel.onPlaybackError(resumeFromMs: progress.positionMs)
                default:
                    break
                }
            }
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            guard let ended = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard !isCleanedUp, player.currentItem === ended else { return }
                let finalDur = progress.durationMs
                viewModel.persistProgress(positionMs: finalDur, durationMs: finalDur, forceWatched: true)
                if viewModel.settingsStore.autoPlayNext && viewModel.stream?.nextEpisodeKey != nil && !isInPipMode {
                    upNextSecondsLeft = 5
                    showUpNextOverlay = true
                    hudVisible = false
                } else {
                    hudVisible = true
                }
            }
        }

        player.replaceCurrentItem(with: item)
    }

    private func configurePlayerObservers() {
        guard timeObserverToken == nil else { return }
        pipCoordinator.onPipStateChanged = { active in
            isInPipMode = active
            if active { hudVisible = false }
        }

        nowPlaying.bindRemoteCommands(
            skipSeconds: viewModel.settingsStore.doubleTapSeekSeconds,
            onPlay: { if !isCleanedUp { player.playImmediately(atRate: playbackRate) } },
            onPause: { player.pause(); persistCurrentProgress() },
            onToggle: { togglePlayPause() },
            onSeekDelta: { deltaSec in
                let deltaMs = Int64(deltaSec * 1000)
                seekBy(deltaMs: deltaMs, label: deltaSec >= 0 ? "+\(Int(deltaSec))s" : "\(Int(deltaSec))s")
            }
        )

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { p, _ in
            Task { @MainActor in
                guard !isCleanedUp else { return }
                switch p.timeControlStatus {
                case .playing:
                    isPlaying = true
                    isBuffering = false
                    hudNonce += 1
                case .paused:
                    isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    isBuffering = true
                @unknown default:
                    break
                }
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { cmTime in
            Task { @MainActor in
                guard !isCleanedUp, player.currentItem != nil else { return }
                let posSec = cmTime.seconds
                let posMs = posSec.isFinite && posSec >= 0 ? Int64(posSec * 1000) : 0
                progress.positionMs = posMs

                if let item = player.currentItem {
                    let durSec = item.duration.seconds
                    if durSec.isFinite && durSec > 0 {
                        progress.durationMs = Int64(durSec * 1000)
                    }
                    if let range = item.loadedTimeRanges.first?.timeRangeValue {
                        let endSec = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
                        if endSec.isFinite && endSec >= 0 {
                            progress.bufferedMs = Int64(endSec * 1000)
                        }
                    }
                }

                viewModel.onPlayheadTick(positionMs: progress.positionMs, durationMs: progress.durationMs)
                activeSkipSegment = SkipPromptLogic.resolveActiveSegment(
                    positionMs: progress.positionMs,
                    durationMs: progress.durationMs,
                    skipTimes: viewModel.skipTimes,
                    skipTimesResolved: viewModel.skipTimesResolved,
                    skipPromptEnabled: viewModel.settingsStore.skipPromptEnabled,
                    fallbackSkipSeconds: viewModel.settingsStore.skipOpSeconds,
                    handledTypes: handledSkipTypes
                )

                nowPlaying.updateMetadata(
                    title: viewModel.animeTitle,
                    episodeLabel: viewModel.stream?.episodeLabel ?? "",
                    positionSec: Double(progress.positionMs) / 1000.0,
                    durationSec: Double(progress.durationMs) / 1000.0,
                    playbackRate: player.rate
                )

                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                if nowMs - lastPersistedAtMs >= 15_000 && progress.durationMs > 0 {
                    lastPersistedAtMs = nowMs
                    viewModel.persistProgress(positionMs: progress.positionMs, durationMs: progress.durationMs)
                }
            }
        }
    }

    private func togglePlayPause() {
        guard !isCleanedUp, player.currentItem?.status == .readyToPlay else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            persistCurrentProgress()
            hudVisible = true
        } else {
            player.playImmediately(atRate: playbackRate)
            hudNonce += 1
        }
    }

    private func seekBy(deltaMs: Int64, label: String) {
        let target = max(0, min(progress.durationMs > 0 ? progress.durationMs : Int64.max, progress.positionMs + deltaMs))
        seekTo(ms: target)
        seekFeedback = label
        seekFeedbackNonce += 1
    }

    private func seekTo(ms: Int64) {
        guard !isCleanedUp, player.currentItem != nil else { return }
        let clamped = max(0, ms)
        progress.positionMs = clamped
        let cm = CMTime(value: clamped, timescale: 1000)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        viewModel.onPlayheadTick(positionMs: clamped, durationMs: progress.durationMs)
        nowPlaying.updateMetadata(
            title: viewModel.animeTitle,
            episodeLabel: viewModel.stream?.episodeLabel ?? "",
            positionSec: Double(clamped) / 1000,
            durationSec: Double(progress.durationMs) / 1000,
            playbackRate: player.rate,
            force: true
        )
        persistCurrentProgress()
    }

    private func executeSkip(segment: SkipSegment) {
        handledSkipTypes.insert(segment.type)
        activeSkipSegment = nil
        let action = SkipPromptLogic.resolveSkipAction(
            segment: segment,
            currentPositionMs: progress.positionMs,
            durationMs: progress.durationMs,
            fallbackSkipSeconds: viewModel.settingsStore.skipOpSeconds,
            hasNextEpisode: viewModel.stream?.nextEpisodeKey != nil
        )
        if action.kind == .nextEpisode, let nextKey = viewModel.stream?.nextEpisodeKey {
            viewModel.persistProgress(positionMs: progress.durationMs, durationMs: progress.durationMs, forceWatched: true)
            switchToEpisode(nextKey)
        } else {
            seekTo(ms: action.targetPositionMs)
            seekFeedback = action.feedbackLabel
            seekFeedbackNonce += 1
        }
    }

    private func cycleSpeed() {
        if let idx = speedOptions.firstIndex(of: playbackRate) {
            playbackRate = speedOptions[(idx + 1) % speedOptions.count]
        } else {
            playbackRate = 1.0
        }
        if isPlaying {
            player.rate = playbackRate
        }
    }

    private func switchToEpisode(_ nextEpisodeKey: String) {
        persistCurrentProgress()
        player.pause()
        showUpNextOverlay = false
        progress.positionMs = 0
        progress.durationMs = 0
        progress.bufferedMs = 0
        viewModel.loadEpisode(episodeKey: nextEpisodeKey)
    }

    private func flashUnlockHint() {
        showUnlockHint = true
        unlockHintTask?.cancel()
        unlockHintTask = Task {
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            showUnlockHint = false
        }
    }

    private func persistCurrentProgress() {
        if progress.durationMs > 0 {
            lastPersistedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            viewModel.persistProgress(positionMs: progress.positionMs, durationMs: progress.durationMs)
        }
    }

    private func exitPlayer() {
        cleanupPlayer()
        onDismiss()
    }

    private func cleanupPlayer() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        unlockHintTask?.cancel()
        unlockHintTask = nil
        persistCurrentProgress()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        pipCoordinator.stopPip()
        pipCoordinator.onPipStateChanged = nil
        nowPlaying.clearRemoteCommands()
        viewModel.shutdown()
        if let originalBrightness { brightnessScreen?.brightness = originalBrightness }
        brightnessScreen = nil
        originalBrightness = nil
        stopAudioSession()
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationManager.shared.unlockAll()
    }

    private func startAudioSession() {
        guard !hasAudioSession else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
            hasAudioSession = true
        } catch {
            Self.logger.error("Could not activate playback audio: \(error.localizedDescription)")
        }
    }

    private func stopAudioSession() {
        guard hasAudioSession else { return }
        hasAudioSession = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Could not deactivate playback audio: \(error.localizedDescription)")
        }
    }
}
