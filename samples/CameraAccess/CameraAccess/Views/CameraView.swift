/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraView.swift
//
// The capture screen: a full-bleed camera preview with controls overlaid on a
// scrim. Walks the SDK's camera lifecycle as explicit steps (Start Session →
// Start Streaming → Capture / Record → Stop Streaming → End Session) and shows the
// live DeviceSessionState / StreamState so the state machine is legible.
//

import AVFoundation
import MWDATCore
import Speech
import SwiftUI
import UIKit

private let updateRequiredTitle = "Update required"

struct CameraView: View {
  @State private var viewModel: CameraViewModel
  @Bindable var wearablesVM: WearablesViewModel
  @State private var showSettingsMenu: Bool = false
  @State private var isLaunchingUpdate: Bool = false
  @State private var showArmCommands: Bool = false

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self._viewModel = State(wrappedValue: CameraViewModel(wearables: wearables))
    self._wearablesVM = Bindable(wearablesVM)
  }

  private var isUpdateRequired: Bool {
    wearablesVM.requiresFirmwareUpdate
  }

  /// Whether the preview is live or tearing down — drives the in-row Preview
  /// toggle's icon, id, and action. (Recording implies a live preview.)
  private var previewIsActive: Bool {
    viewModel.isStreaming || viewModel.isRecording || viewModel.streamState == .stopping
  }

  var body: some View {
    ZStack {
      // Full-bleed preview (or a dark placeholder) fills the screen so overlaying
      // the controls never reflows it.
      previewBackground
        .edgesIgnoringSafeArea(.all)

      if let preview = viewModel.activePreview {
        CapturePreviewView(
          preview: preview,
          onDismiss: { viewModel.dismissCapturePreview() }
        )
        .transition(.opacity)
        .zIndex(1)
      }

      // Tap outside the open top-bar settings menu dismisses it.
      if showSettingsMenu {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
              showSettingsMenu = false
            }
          }
          .edgesIgnoringSafeArea(.all)
      }

      VStack(spacing: 0) {
        topBar
          .padding(.horizontal, 20)
          .padding(.top, 16)
          .padding(.bottom, 40)
          .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
              .edgesIgnoringSafeArea(.top)
          )

        Spacer(minLength: 0)

        bottomBar
      }
    }
    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: viewModel.hasSession)
    .animation(.easeInOut(duration: 0.2), value: previewIsActive)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isStreaming)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isPaused)
    .animation(.easeInOut(duration: 0.2), value: viewModel.includeAudioInStream)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
    .alert("Something went wrong", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
    .alert("Allow camera access", isPresented: $viewModel.showCameraPermissionRedirectConfirm) {
      Button("Continue") { Task { await viewModel.confirmCameraPermissionRedirect() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("To preview your glasses camera, you'll be taken to the Meta AI app to grant access, then returned here.")
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $showArmCommands) {
      ArmCommandView()
    }
  }

  // MARK: - Preview background

  @ViewBuilder
  private var previewBackground: some View {
    ZStack {
      Color.black
      if viewModel.showsLivePreview {
        // Live preview, the frozen last frame while paused, or the last frame held
        // while the stream tears down — so the paused badge / stop loader overlays
        // the preview rather than the start-streaming screen.
        LivePreviewView(viewModel: viewModel)
        if viewModel.isPaused {
          // Dim the frozen frame so the badge reads as intentionally paused.
          Color.black.opacity(0.35)
          pausedOverlay
        }
      } else if !viewModel.isBusy {
        statusPlaceholder
      }

      // Loader overlays whatever is behind it during any in-flight transition.
      if viewModel.isBusy {
        loadingOverlay
      }
    }
  }

  /// Label over the frozen preview while paused, so a held frame reads as
  /// intentionally paused (with how to resume) rather than a stalled feed. A
  /// `pause.fill` status glyph (not a circled/button shape) — resume is a glasses
  /// gesture, not an on-screen control.
  private var pausedOverlay: some View {
    VStack(spacing: 8) {
      Image(systemName: "pause.fill")
        .font(.system(size: 36))
        .foregroundStyle(.white)
      Text("Paused")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)
      Text("Tap your glasses to resume.")
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.white.opacity(0.7))
    }
    .padding(.horizontal, 24)
    .accessibilityIdentifier("paused_overlay")
  }

  /// Dimmed spinner shown over the preview (or placeholder) while a session/stream
  /// start or stop is in flight.
  private var loadingOverlay: some View {
    ZStack {
      Color.black.opacity(0.35)
      ProgressView()
        .scaleEffect(1.5)
        .tint(.white)
    }
  }

  @ViewBuilder
  private var statusPlaceholder: some View {
    if !viewModel.hasActiveDevice {
      placeholder(title: "Put on your glasses", subtitle: nil, showWaitingRow: true)
    } else if isUpdateRequired {
      placeholder(title: updateRequiredTitle, subtitle: "Apply the update to start your camera.", showWaitingRow: false)
    } else if !viewModel.hasSession {
      placeholder(title: "Ready", subtitle: "Start a session to connect to your glasses.", showWaitingRow: false)
    } else if viewModel.isPaused {
      placeholder(title: "Paused", subtitle: "Tap your glasses to resume.", showWaitingRow: false)
    } else {
      placeholder(title: "Session started", subtitle: "Start the preview to see the live camera feed.", showWaitingRow: false)
    }
  }

  private func placeholder(title: String, subtitle: String?, showWaitingRow: Bool) -> some View {
    VStack(spacing: 12) {
      Image(.cameraAccessIcon)
        .resizable()
        .renderingMode(.template)
        .foregroundStyle(.white)
        .aspectRatio(contentMode: .fit)
        .frame(width: 88)

      Text(title)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)

      if let subtitle {
        Text(subtitle)
          .font(.system(size: 15))
          .multilineTextAlignment(.center)
          .foregroundStyle(Color.white.opacity(0.7))
      }

      if showWaitingRow {
        HStack(spacing: 8) {
          Image(systemName: "hourglass")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(Color.white.opacity(0.7))
            .frame(width: 16, height: 16)
          Text("Waiting for an active device")
            .font(.system(size: 14))
            .foregroundStyle(Color.white.opacity(0.7))
        }
      }
    }
    .padding(.horizontal, 24)
  }

  // MARK: - Top bar

  /// Top bar: compact live SDK state stacked on the left so the lifecycle is
  /// legible without heavy chrome, settings/disconnect on the right.
  private var topBar: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        statusChip(label: "Session", value: viewModel.sessionStateText, active: viewModel.isSessionActive, present: viewModel.hasSession)
        statusChip(label: "Stream", value: viewModel.streamStateText, active: viewModel.isStreaming, present: viewModel.hasStream)
      }

      Spacer()

      // Top bar carries only the app-level settings/Disconnect control.
      iconButton("gearshape", id: "settings_button") {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          showSettingsMenu.toggle()
        }
      }
      .overlay(alignment: .trailing) {
        if showSettingsMenu {
          CustomButton(
            title: "Disconnect",
            style: .destructive,
            isDisabled: wearablesVM.registrationState != .registered
          ) {
            wearablesVM.disconnectGlasses()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { showSettingsMenu = false }
          }
          .frame(width: 120)
          .offset(y: 44)
          .transition(.scale(scale: 0.01, anchor: .topTrailing).combined(with: .opacity))
        }
      }
    }
  }

  private func statusChip(label: String, value: String, active: Bool, present: Bool) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(active ? Color.green : (present ? Color.yellow : Color.gray))
        .frame(width: 7, height: 7)
      Text("\(label): \(value)")
        .font(.system(size: 12, weight: .medium))
        .monospaced()
        .foregroundStyle(Color.white.opacity(0.85))
    }
  }

  private func iconButton(_ systemName: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .padding(.leading, 16)
    }
    .accessibilityIdentifier(id)
  }

  // MARK: - Bottom bar

  private var bottomBar: some View {
    VStack(spacing: 14) {
      if isUpdateRequired {
        updateControls
      } else {
        // Reserved capture-row space + a single persistent button hold the button at
        // a fixed Y across every state.
        armCommandRow
        captureRow
        anchoredPrimaryButton
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.top, 48)
    .padding(.bottom, 28)
    .background(
      LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        .edgesIgnoringSafeArea(.bottom)
    )
  }

  /// Opens the arm voice-command sheet. The command channel is independent
  /// of the camera session: it talks to the yahboom executor over Wi-Fi.
  private var armCommandRow: some View {
    capturePill(icon: "mic.fill", title: "机械臂口令", contentTint: .white, id: "arm_command_button") {
      showArmCommands = true
    }
  }

  /// In-session toolbar (Preview / Photo / Record / Mic), kept laid out so the
  /// session button below holds a fixed Y. Hidden without a session; Preview leads as
  /// the gateway and is the lone enabled control in session-ready, the rest enabling
  /// once streaming.
  private var captureRow: some View {
    HStack(spacing: 10) {
      previewPill
      photoButton
      recordPill
      micToggle
    }
    .opacity(viewModel.hasSession ? 1 : 0)
  }

  /// Photo and Record need a live stream.
  private var captureControlsEnabled: Bool { viewModel.isStreaming }
  /// Record/Stop stays available while recording even if the stream is paused, so a
  /// pause can't trap an in-progress recording; starting still needs a live stream.
  private var recordControlEnabled: Bool { viewModel.isStreaming || viewModel.isRecording }
  /// Mic additionally locks once recording starts — the audio setting can't change
  /// mid-take.
  private var micEnabled: Bool { viewModel.isStreaming && !viewModel.isRecording }

  /// Photo capture as a compact icon (no label) so the Preview and Record pills keep
  /// room for text. Enabled while streaming, including during a recording.
  private var photoButton: some View {
    Button {
      viewModel.capturePhoto()
    } label: {
      Image(systemName: "camera.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 50, height: 50)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
    }
    .accessibilityIdentifier("capture_button")
    .disabled(!captureControlsEnabled)
    .opacity(captureControlsEnabled ? 1 : 0.35)
  }

  /// Preview on/off — the gateway for capture. The eye icon flips and dims when off;
  /// locked mid-recording so a recording can't lose its feed.
  private var previewPill: some View {
    capturePill(
      icon: previewIsActive ? "eye.fill" : "eye.slash.fill",
      title: "Preview",
      contentTint: .white,
      id: previewIsActive ? "stop_preview_button" : "start_preview_button"
    ) {
      if previewIsActive {
        viewModel.stopStreaming()
      } else {
        Task { await viewModel.startStreaming() }
      }
    }
    .disabled(previewToggleDisabled)
    .opacity(previewToggleDisabled ? 0.35 : 1)
  }

  private var previewToggleDisabled: Bool {
    if previewIsActive {
      return viewModel.isRecording || viewModel.isBusy
    }
    return !viewModel.isSessionActive || viewModel.isBusy
  }

  /// The single full-width session button: Start Session, or End Session
  /// (destructive) once a session exists. One instance, never branched, so it never
  /// remounts and holds a fixed Y — only its title / style / id / action change.
  private var anchoredPrimaryButton: some View {
    CustomButton(
      title: viewModel.hasSession ? "End session" : "Start session",
      style: viewModel.hasSession ? .destructive : .primary,
      isDisabled: primaryDisabled
    ) {
      if viewModel.hasSession {
        viewModel.endSession()
      } else {
        viewModel.startSession()
      }
    }
    .accessibilityIdentifier(viewModel.hasSession ? "end_session_button" : "start_session_button")
  }

  /// Start needs an active device; End stays available mid-stream/record — the SDK
  /// cascades the stop, so only an in-flight transition disables it.
  private var primaryDisabled: Bool {
    if viewModel.hasSession {
      return viewModel.isBusy
    }
    return viewModel.isBusy || !viewModel.hasActiveDevice
  }

  private func primaryButton(_ title: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
    CustomButton(title: title, style: .primary, isDisabled: disabled, action: action)
      .accessibilityIdentifier(id)
  }

  /// Frosted icon+label capsule for the capture actions. `contentTint` colors both
  /// the icon and label so on/off dims them together (see `previewPill`).
  private func capturePill(icon: String, title: String, contentTint: Color = .white, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(contentTint)
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(contentTint)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 50)
      .background(.ultraThinMaterial)
      .clipShape(Capsule())
    }
    .accessibilityIdentifier(id)
  }

  /// Record/Stop capsule. Morphs in place while recording (red fill + the live timer
  /// in the isolated `RecordingTimerLabel`) so the bar keeps its shape and the
  /// per-frame timer doesn't re-render the surrounding controls.
  private var recordPill: some View {
    Button {
      viewModel.toggleRecording()
    } label: {
      Group {
        if viewModel.isRecording {
          RecordingTimerLabel(viewModel: viewModel)
        } else {
          HStack(spacing: 8) {
            Image(systemName: "video.fill")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(Color.recordAccent)
            Text("Record")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.white)
          }
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 50)
      .background {
        if viewModel.isRecording {
          ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.recordAccent.opacity(0.50))
          }
        } else {
          Capsule().fill(.ultraThinMaterial)
        }
      }
    }
    .accessibilityIdentifier("record_button")
    .disabled(!recordControlEnabled)
    .opacity(recordControlEnabled ? 1 : 0.35)
  }

  /// Sound-in-video toggle. Brightens on, dims/slashes when muted; locked until
  /// streaming and during recording. Denied reads as off and, since iOS won't
  /// re-prompt, tapping it opens Settings instead of toggling.
  private var micToggle: some View {
    let isOn = !viewModel.micDenied && viewModel.includeAudioInStream
    return Button {
      if viewModel.micDenied {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      } else {
        viewModel.includeAudioInStream.toggle()
      }
    } label: {
      Image(systemName: isOn ? "mic.fill" : "mic.slash.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(isOn ? .white : Color.white.opacity(0.45))
        .frame(width: 50, height: 50)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
    }
    .disabled(!micEnabled)
    .opacity(micEnabled ? 1 : 0.35)
    .accessibilityIdentifier("mic_toggle")
  }

  // MARK: - Update controls

  @ViewBuilder
  private var updateControls: some View {
    UpdateRequiredMessage()
    // Gate the button while the external update flow launches so a double-tap can't
    // fire it twice; re-enabled once the await returns.
    primaryButton("Update firmware", id: "update_firmware_button", disabled: isLaunchingUpdate) {
      isLaunchingUpdate = true
      Task {
        await wearablesVM.openFirmwareUpdate()
        isLaunchingUpdate = false
      }
    }
  }
}

// MARK: - Live preview

/// The streaming preview image. Isolated from `CameraView` so frequent
/// (~24fps) `currentVideoFrame` updates re-render only this view, not the
/// surrounding controls.
private struct LivePreviewView: View {
  var viewModel: CameraViewModel

  var body: some View {
    if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
      GeometryReader { geometry in
        Image(uiImage: videoFrame)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
      }
    } else {
      ProgressView()
        .scaleEffect(1.5)
        .tint(.white)
    }
  }
}

// MARK: - Recording timer

/// Elapsed-time label shown inside the record button while recording. Self-drives
/// off the recording start via `TimelineView`, so it counts continuously — including
/// through a stream pause — and re-renders only this isolated label.
private struct RecordingTimerLabel: View {
  var viewModel: CameraViewModel

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "stop.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.recordAccent)
      // Counts from the actual recording start (first written frame), so it tracks the
      // saved clip and keeps advancing through a pause; shows 00:00 until that frame.
      if let start = viewModel.recordingStartDate {
        TimelineView(.periodic(from: start, by: 1)) { context in
          timerText(context.date.timeIntervalSince(start))
        }
      } else {
        timerText(0)
      }
    }
  }

  private func timerText(_ elapsed: TimeInterval) -> some View {
    Text(elapsed.formattedRecordingTime)
      .font(.system(size: 15, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(.white)
      // Identifier on the Text so UI tests find it regardless of the time value.
      .accessibilityIdentifier("recording_indicator")
  }
}

// MARK: - Update banner

struct UpdateRequiredMessage: View {
  private let message = "Your glasses need a firmware update before Camera Access can start."

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(Color.updateRequiredForeground)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(updateRequiredTitle)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color.updateRequiredForeground)

        Text(message)
          .font(.system(size: 15))
          .foregroundStyle(Color.updateRequiredForeground)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.all, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.updateRequiredBackground)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}


// MARK: - Arm commands (yahboom executor)
//
// Control panel for the chess arm. Pick a move (tap a move button, or type /
// dictate its name with the system keyboard), the app reads it back, and only
// after an explicit on-screen confirmation POSTs {move, confirmed: true} to
// the executor service on the yahboom (port 8767). The executor enforces its
// own whitelist and its on-device dry-run / live mode; this app never talks
// to the arm's joint service directly.
//
// v3: in-app speech recognition was removed after a SIGTRAP crash on first
// use (v1/v2): the crash hit instantly on tapping "start listening", before
// any permission prompt, and the crash log carried no app-level backtrace.
// Input is therefore tap + system keyboard dictation for now (dictation is
// handled by iOS itself and needs no app speech permission). Read-back TTS
// stays - AVSpeechSynthesizer is already proven in this app. A step marker
// is kept in UserDefaults so any future crash leaves a visible trace.

private let armExecutorURL = URL(string: "http://192.168.1.97:8767/command")!
private let armStepMarkerKey = "armCmdLastStep"

@MainActor
@Observable
final class ArmCommandClient {
  struct Move: Identifiable, Equatable {
    let key: String
    let label: String
    let phrases: [String]
    var id: String { key }
  }

  // Mirrors the executor whitelist on the yahboom. Uncalibrated or
  // unconfirmed moves (e.g. g3g4) are deliberately absent here too.
  static let moves: [Move] = [
    Move(key: "b2e2", label: "炮八平五", phrases: ["炮八平五"]),
    Move(key: "b0c2", label: "马八进七", phrases: ["马八进七"]),
    Move(key: "h0g2", label: "马二进三", phrases: ["马二进三"]),
    Move(key: "a0b0", label: "车九平八", phrases: ["车九平八"]),
    Move(key: "c2d4", label: "马七进六", phrases: ["马七进六"]),
    Move(key: "c3c4", label: "兵七进一", phrases: ["兵七进一"]),
    Move(key: "e3e4", label: "兵五进一", phrases: ["兵五进一"]),
    Move(key: "home", label: "回位", phrases: ["回位", "回到原位"]),
  ]

  enum Phase: Equatable {
    case idle
    case confirming(Move)
    case sending(Move)
    case done(String)
    case failed(String)
  }

  private(set) var phase: Phase = .idle
  private(set) var logLines: [String] = []

  var pendingMove: Move? {
    if case .confirming(let move) = phase { return move }
    return nil
  }
  var isBusy: Bool {
    switch phase {
    case .confirming, .sending: return true
    default: return false
    }
  }
  var statusText: String {
    switch phase {
    case .idle: return "点一步，或用键盘听写输入步名"
    case .confirming(let move): return "已选「\(move.label)」，确认后发送"
    case .sending(let move): return "正在发送「\(move.label)」…"
    case .done(let text): return text
    case .failed(let text): return "出错：\(text)"
    }
  }

  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private var confirmTimer: Task<Void, Never>?

  private func mark(_ step: String) {
    UserDefaults.standard.set(step, forKey: armStepMarkerKey)
  }

  // MARK: Controls used by the view

  func selectMove(_ move: Move) {
    guard !isBusy else { return }
    mark("选中步法 \(move.key)")
    phase = .confirming(move)
    appendLog("选中：\(move.label)（\(move.key)），待确认")
    speak("你要走\(move.label)，请点确认发送")
    startConfirmTimer()
  }

  func submitText(_ raw: String) {
    let text = raw.replacingOccurrences(of: " ", with: "")
    guard !text.isEmpty, !isBusy else { return }
    if let move = Self.moves.first(where: { move in
      move.phrases.contains(where: { text.contains($0) })
    }) {
      selectMove(move)
    } else {
      phase = .failed("没匹配到步名：\(text)")
      appendLog("输入未匹配：\(text)")
      speak("没匹配到这一步")
    }
  }

  func confirmSend() {
    guard case .confirming(let move) = phase else { return }
    mark("点确认发送")
    beginSend(move)
  }

  func cancelPending() {
    guard case .confirming = phase else { return }
    finishCancel(reason: "已取消")
  }

  func stopAll() {
    confirmTimer?.cancel()
    synthesizer.stopSpeaking(at: .immediate)
    if pendingMove != nil {
      phase = .idle
    }
  }

  // MARK: Confirmation timeout

  private func startConfirmTimer() {
    confirmTimer?.cancel()
    confirmTimer = Task { @MainActor in
      try? await Task.sleep(for: .seconds(15))
      guard !Task.isCancelled, case .confirming = self.phase else { return }
      self.finishCancel(reason: "确认超时，已取消")
    }
  }

  private func finishCancel(reason: String) {
    confirmTimer?.cancel()
    phase = .idle
    appendLog(reason)
    speak(reason)
  }

  // MARK: Sending

  private func beginSend(_ move: Move) {
    confirmTimer?.cancel()
    phase = .sending(move)
    mark("发送中 \(move.key)")
    appendLog("发送指令：\(move.key)")
    Task { @MainActor in
      do {
        var request = URLRequest(url: armExecutorURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
          "move": move.key,
          "confirmed": true,
          "source": "glasses-app",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let object = try? JSONSerialization.jsonObject(with: data)
        let dict = object as? [String: Any]
        if status == 200, (dict?["ok"] as? Bool) == true {
          let mode = dict?["mode"] as? String ?? "?"
          let text = mode == "dry-run"
            ? "已发送\(move.label)，当前干跑模式，机械臂没有动"
            : "已执行\(move.label)"
          phase = .done(text)
          mark("已完成一轮")
          appendLog("执行端回复：\(text)")
          speak(text)
        } else {
          let message = (dict?["error"] as? String) ?? "HTTP \(status)"
          phase = .failed("执行端拒绝：\(message)")
          appendLog("被拒绝：\(message)")
          speak("发送失败")
        }
      } catch {
        phase = .failed("网络错误：\(error.localizedDescription)")
        appendLog("网络错误：\(error.localizedDescription)")
        speak("发送失败")
      }
    }
  }

  // MARK: Speech out + log

  private func speak(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    synthesizer.stopSpeaking(at: .immediate)
    synthesizer.speak(utterance)
  }

  private func appendLog(_ line: String) {
    logLines.append(line)
    if logLines.count > 30 {
      logLines.removeFirst(logLines.count - 30)
    }
  }
}

struct ArmCommandView: View {
  @State private var client = ArmCommandClient()
  @State private var inputText: String = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(client.statusText)
            .font(.system(size: 18, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))

          if let pending = client.pendingMove {
            VStack(spacing: 10) {
              Text("确认发送「\(pending.label)」？")
                .font(.system(size: 17, weight: .semibold))
              HStack(spacing: 12) {
                Button {
                  client.confirmSend()
                } label: {
                  Text("确认发送").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                  client.cancelPending()
                } label: {
                  Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
              }
            }
            .padding()
            .background(Color.orange.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("点选步法").font(.headline)
            ForEach(ArmCommandClient.moves) { move in
              Button {
                client.selectMove(move)
              } label: {
                HStack {
                  Text(move.label)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                  Spacer()
                  Text(move.key).monospaced().foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
              }
              .disabled(client.isBusy)
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("或输入 / 听写步名").font(.headline)
            HStack(spacing: 10) {
              TextField("如：兵五进一（可点键盘麦克风听写）", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.go)
                .onSubmit {
                  client.submitText(inputText)
                  inputText = ""
                }
              Button("走这步") {
                client.submitText(inputText)
                inputText = ""
              }
              .buttonStyle(.bordered)
              .disabled(client.isBusy)
            }
          }

          NavigationLink {
            SpeechDiagView()
          } label: {
            HStack {
              Text("语音识别诊断")
                .font(.system(size: 16, weight: .medium))
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
          }

          if !client.logLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("记录").font(.headline)
              ForEach(Array(client.logLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                  .font(.system(size: 12))
                  .monospaced()
                  .foregroundStyle(.secondary)
              }
            }
          }

          if let marker = UserDefaults.standard.string(forKey: armStepMarkerKey) {
            Text("诊断标记（上次走到）：\(marker)")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
        .padding()
      }
      .navigationTitle("机械臂口令")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("关闭") {
            client.stopAll()
            dismiss()
          }
        }
      }
      .onDisappear {
        client.stopAll()
      }
    }
  }
}


// MARK: - Speech recognition diagnostics
//
// Step-by-step isolation page for the v1 crash: the original flow chained
// authorization -> session -> engine -> tap -> recognition task in one go
// and trapped instantly. Here each stage is a separate button, executed only
// when tapped, with a durable on-disk marker written BEFORE the stage runs -
// so if a stage kills the app, reopening this page shows exactly where it
// died ("上次标记"). Stage results (statuses, formats, errors) stay visible
// on the page for reporting.

@MainActor
@Observable
final class SpeechDiagClient {
  private(set) var lastMarker: String = "（无）"
  private(set) var authText: String = "未执行"
  private(set) var micText: String = "未执行"
  private(set) var sessionText: String = "未执行"
  private(set) var formatText: String = "未执行"
  private(set) var engineText: String = "未执行"
  private(set) var taskText: String = "未执行"
  private(set) var transcriptText: String = ""

  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
  @ObservationIgnored private var task: SFSpeechRecognitionTask?
  @ObservationIgnored private var tapInstalled = false

  private var markerURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("arm_diag_marker.txt")
  }

  private func mark(_ text: String) {
    try? text.write(to: markerURL, atomically: true, encoding: .utf8)
    UserDefaults.standard.set(text, forKey: armStepMarkerKey)
    UserDefaults.standard.synchronize()
  }

  func pageOpened() {
    if let saved = try? String(contentsOf: markerURL, encoding: .utf8) {
      lastMarker = saved
    }
    mark("0-诊断页已打开")
  }

  // Stage 1: speech recognition authorization only.
  // The request goes through a nonisolated async helper on purpose: a
  // completion closure formed inside this @MainActor class inherits
  // MainActor isolation, TCC delivers the reply on a background XPC queue,
  // and the Swift executor check on closure entry traps (SIGTRAP - the
  // crash localized by the 2026-11-03 diagnostic build, see thread with
  // dispatch_assert_queue under SpeechDiagClient.stage1Auth).
  func stage1Auth() {
    mark("1-语音授权-开始")
    authText = "请求中…"
    Task { @MainActor in
      let status = await Self.requestSpeechAuthorizationAsync()
      mark("1-语音授权-完成")
      switch status {
      case .authorized: authText = "已授权"
      case .denied: authText = "被拒绝"
      case .restricted: authText = "受限制（系统/家长控制）"
      case .notDetermined: authText = "未决定"
      @unknown default: authText = "未知状态"
      }
    }
  }

  nonisolated private static func requestSpeechAuthorizationAsync() async
    -> SFSpeechRecognizerAuthorizationStatus
  {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }

  // Stage 2: microphone record permission only. Same nonisolated-helper
  // pattern as stage 1 - the record-permission reply also arrives off the
  // main queue.
  func stage2Mic() {
    mark("2-麦克风授权-开始")
    micText = "请求中…"
    Task { @MainActor in
      let granted = await Self.requestRecordPermissionAsync()
      mark("2-麦克风授权-完成")
      micText = granted ? "已允许" : "被拒绝"
    }
  }

  nonisolated private static func requestRecordPermissionAsync() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  // Stage 3: audio session configuration only (same options as v1).
  func stage3Session() {
    mark("3-音频会话-开始")
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord, mode: .default,
        options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
      sessionText = "配置成功；当前输入：\(inputs.isEmpty ? "（无）" : inputs)"
      mark("3-音频会话-完成")
    } catch {
      sessionText = "失败：\(error.localizedDescription)"
      mark("3-音频会话-失败")
    }
  }

  // Stage 4: create the engine, prepare it, read the input format only.
  func stage4Format() {
    mark("4-引擎格式-开始")
    if engine == nil {
      engine = AVAudioEngine()
    }
    guard let engine else { return }
    // No prepare() here: on an empty graph it throws an uncaught
    // NSException from AVAudioEngineGraph::Initialize (the stage-4 crash,
    // see the 2026-11-03 11:11 crash log). Reading the input format does
    // not need it, and start() initializes the graph on its own.
    let format = engine.inputNode.outputFormat(forBus: 0)
    formatText = "sampleRate=\(format.sampleRate), channels=\(format.channelCount)"
    mark("4-引擎格式-完成 \(formatText)")
  }

  // Stage 5: install the tap and start the engine (needs stage 4 first).
  func stage5Engine() {
    mark("5-引擎启动-开始")
    guard let engine else {
      engineText = "先执行第 4 步"
      return
    }
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      engineText = "输入格式无效（sampleRate=\(format.sampleRate)），不装采集"
      mark("5-引擎启动-格式无效")
      return
    }
    if request == nil {
      request = SFSpeechAudioBufferRecognitionRequest()
    }
    guard let request else { return }
    if !tapInstalled {
      engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
      }
      tapInstalled = true
    }
    mark("5-tap已装-启动引擎")
    do {
      try engine.start()
      engineText = "引擎运行中"
      mark("5-引擎启动-完成")
    } catch {
      engineText = "启动失败：\(error.localizedDescription)"
      mark("5-引擎启动-失败")
    }
  }

  // Stage 6: create the recognizer and start a recognition task (needs 5).
  func stage6Task() {
    mark("6-识别任务-创建识别器")
    guard let request else {
      taskText = "先执行第 5 步"
      return
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
      taskText = "zh-CN 识别器创建失败（nil）"
      mark("6-识别任务-识别器nil")
      return
    }
    taskText = "识别器可用=\(recognizer.isAvailable)，设备端识别=\(recognizer.supportsOnDeviceRecognition)"
    request.shouldReportPartialResults = true
    request.contextualStrings = ArmCommandClient.moves.flatMap(\.phrases) + ["确认", "取消"]
    mark("6-识别任务-启动")
    task = Self.startRecognitionTask(
      recognizer: recognizer, request: request
    ) { [weak self] text, isFinal, errorText in
      Task { @MainActor in
        guard let self else { return }
        if let text {
          self.transcriptText = text
        }
        if let errorText {
          self.taskText = "任务出错：\(errorText)"
        } else if isFinal {
          self.taskText = "任务结束（final）"
        }
      }
    }
    mark("6-识别任务-运行中")
  }

  // Nonisolated: the recognition result handler must not inherit MainActor
  // isolation either - the Speech daemon calls it back on its own queue.
  nonisolated private static func startRecognitionTask(
    recognizer: SFSpeechRecognizer,
    request: SFSpeechAudioBufferRecognitionRequest,
    onEvent: @escaping @Sendable (_ text: String?, _ isFinal: Bool, _ errorText: String?) -> Void
  ) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
      onEvent(
        result?.bestTranscription.formattedString,
        result?.isFinal ?? false,
        error?.localizedDescription)
    }
  }

  func stopAll() {
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    if let engine {
      if engine.isRunning {
        engine.stop()
      }
      if tapInstalled {
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
      }
    }
    engineText = "已停止"
    taskText = "已停止"
  }
}

struct SpeechDiagView: View {
  @State private var client = SpeechDiagClient()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("上次标记：\(client.lastMarker)")
          .font(.system(size: 13, weight: .semibold))
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.yellow.opacity(0.2))
          .clipShape(RoundedRectangle(cornerRadius: 10))

        Text("从 1 到 6 依次点，每步点完停一下看结果。若某一步 App 闪退，重开 App 回到本页，看「上次标记」停在哪一步。")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)

        stageButton("1 请求语音识别授权", result: client.authText) { client.stage1Auth() }
        stageButton("2 请求麦克风授权", result: client.micText) { client.stage2Mic() }
        stageButton("3 配置音频会话", result: client.sessionText) { client.stage3Session() }
        stageButton("4 读麦克风输入格式", result: client.formatText) { client.stage4Format() }
        stageButton("5 装采集并启动引擎", result: client.engineText) { client.stage5Engine() }
        stageButton("6 启动识别任务", result: client.taskText) { client.stage6Task() }

        if !client.transcriptText.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("识别听到：").font(.headline)
            Text(client.transcriptText)
              .font(.system(size: 16, weight: .medium))
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.green.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 10))
        }

        Button(role: .destructive) {
          client.stopAll()
        } label: {
          Text("停止全部").frame(maxWidth: .infinity).frame(height: 44)
        }
        .buttonStyle(.bordered)
      }
      .padding()
    }
    .navigationTitle("语音识别诊断")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      client.pageOpened()
    }
    .onDisappear {
      client.stopAll()
    }
  }

  private func stageButton(_ title: String, result: String, action: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: action) {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 44)
      }
      .buttonStyle(.borderedProminent)
      Text(result)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
  }
}
