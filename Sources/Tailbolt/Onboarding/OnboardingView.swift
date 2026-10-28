import AppKit
import SwiftUI
import TailboltCore

/// Root of the onboarding window: stage on top, text block, footer. One `OnboardingState` drives it.
struct OnboardingView: View {
    let state: OnboardingState
    @State private var smoother = ParallaxSmoother()
    @State private var hoverTarget: CGSize = .zero

    private var controller: OnboardingController { .shared }

    var body: some View {
        VStack(spacing: 0) {
            // One self-contained view per page (stage + hairline + text, fixed heights) so a page change is a
            // pure slide/crossfade and no layout animates in between.
            ZStack(alignment: .top) {
                pageView(for: state.page)
                    .id(state.page)
                    .transition(pageTransition)
            }
            .frame(width: OnboardingTokens.windowWidth, height: OnboardingTokens.windowHeight - OnboardingTokens.footerHeight, alignment: .top)
            .clipped()
            footer
        }
        .frame(width: OnboardingTokens.windowWidth, height: OnboardingTokens.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()   // the stage runs under the transparent title bar
        .environment(state)
    }

    private func pageView(for page: OnboardingPage) -> some View {
        VStack(spacing: 0) {
            stage(for: page)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard page == .welcome, !state.reduceMotion else { hoverTarget = .zero; return }
                    switch phase {
                    case .active(let p):
                        let h = page.stageHeight
                        hoverTarget = CGSize(width: (p.x - 360) / 360 * 6, height: (p.y - h / 2) / (h / 2) * 6)
                    case .ended:
                        hoverTarget = .zero
                    }
                }
            Color(nsColor: .separatorColor).opacity(0.5).frame(height: 1)
            ZStack(alignment: .top) { textBlock(for: page) }
                .frame(width: OnboardingTokens.windowWidth,
                       height: OnboardingTokens.windowHeight - OnboardingTokens.footerHeight - 1 - page.stageHeight,
                       alignment: .top)
                .clipped()
        }
    }

    /// Old page fades out fast, the new one slides in 24 pt right behind it (never two pages at full strength).
    private var pageTransition: AnyTransition {
        if state.reduceMotion {
            return .asymmetric(insertion: .opacity.animation(.easeInOut(duration: 0.2).delay(0.1)),
                               removal: .opacity.animation(.easeInOut(duration: 0.12)))
        }
        let forward = state.direction == .forward
        return .asymmetric(
            insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity)
                .animation(.spring(response: 0.42, dampingFraction: 0.88).delay(0.08)),
            removal: .offset(x: forward ? -16 : 16).combined(with: .opacity).animation(.easeIn(duration: 0.14)))
    }

    // MARK: stage

    @ViewBuilder
    private func stage(for page: OnboardingPage) -> some View {
        let rm = state.reduceMotion
        switch page {
        case .welcome:
            let target = hoverTarget, smoother = smoother
            StageView(height: page.stageHeight, label: "Animation: Tailbolt verbindet sich mit vier Geräten im Tailnet und schickt Dateien hin und her.") { t in
                RadarStage(elapsed: t, parallax: smoother.step(toward: target), reduceMotion: rm)
            }
        case .tailscale:
            let connected = state.tailscaleConnected
            StageView(height: page.stageHeight, label: "Animation: Geräte verbinden sich zu einem Netzwerk.") { t in
                TailscaleStage(elapsed: t, connected: connected, reduceMotion: rm)
            }
        case .send:
            StageView(height: page.stageHeight, label: "Animation: Eine Datei wird aus dem Finder gezogen, der Cursor schüttelt, das Shelf erscheint und die Datei wird auf ein Gerät gelegt.") { t in
                ShakeStage(elapsed: t, reduceMotion: rm)
            }
        case .devices:
            let devices = OnboardingMocks.bubbleDevices()
            StageView(height: page.stageHeight, label: "Animation: Fünf Geräte im Tailnet – fremde, eigene und eines via Taildrop; ein Ordner wird auf eines gelegt.") { t in
                BubblesStage(elapsed: t, devices: devices, reduceMotion: rm)
            }
        case .receive:
            StageView(height: page.stageHeight, label: "Animation: Oben rechts erscheint eine Karte, Annehmen wird geklickt, die Datei landet in Downloads; eine zweite Karte wird automatisch angenommen.") { t in
                CardsStage(elapsed: t, reduceMotion: rm)
            }
        case .shortcuts:
            StageView(height: page.stageHeight, label: "Animation: Das Tastenkürzel Control Option Command B öffnet das Shelf; eine Datei wird auf das Menüleisten-Symbol gezogen.") { t in
                KeysStage(elapsed: t, reduceMotion: rm)
            }
        case .ready:
            let live = OnboardingMocks.liveDevices()
            let caption = live.real ? OnboardingStrings.readyLiveCaption(live.devices.count, AppModel.shared.myName) : OnboardingStrings.readyLiveNone
            StageView(height: page.stageHeight, label: "Animation: Tailbolt in der Mitte, deine Geräte darum herum.") { t in
                LiveStage(elapsed: t, devices: live.devices, real: live.real, caption: caption, reduceMotion: rm)
            }
        }
    }

    // MARK: text blocks

    @ViewBuilder
    private func textBlock(for page: OnboardingPage) -> some View {
        Group {
            switch page {
            case .welcome: WelcomeBlock()
            case .tailscale: TailscaleBlock()
            case .send: SendBlock()
            case .devices: DevicesBlock()
            case .receive: ReceiveBlock()
            case .shortcuts: ShortcutsBlock()
            case .ready: ReadyBlock()
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity)
    }

    // MARK: footer

    private var footer: some View {
        ZStack {
            HStack(spacing: 8) {
                if state.page != .ready {
                    SkipButton(title: OnboardingStrings.navSkip) { controller.skip() }
                }
                Spacer()
                let hasBack = state.previous(before: state.page) != nil
                Button(OnboardingStrings.navBack) { controller.back() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .opacity(hasBack ? 1 : 0)
                    .disabled(!hasBack)
                Button { controller.next() } label: {
                    Text(primaryLabel).frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)

            PageDots(count: OnboardingPage.dotted.count, current: state.page.dotIndex,
                     canJump: { controller.canJump(toDot: $0) }, onJump: { controller.jump(toDot: $0) })
        }
        .frame(height: OnboardingTokens.footerHeight)
    }

    private var primaryLabel: String {
        switch state.page {
        case .welcome: return OnboardingStrings.welcomeCTA
        case .ready: return OnboardingStrings.navDone
        default: return OnboardingStrings.navNext
        }
    }
}

/// Eases the mouse-driven parallax toward its target once per animation frame.
final class ParallaxSmoother {
    private var current = CGSize.zero
    private var last = Date()

    func step(toward target: CGSize) -> CGSize {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(last))
        last = now
        let k = 1 - exp(-dt / 0.12)
        current = CGSize(width: current.width + (target.width - current.width) * k,
                         height: current.height + (target.height - current.height) * k)
        return current
    }
}

// MARK: - Shared text styles

private struct PageTitle: View {
    let text: String
    var hero = false
    var body: some View {
        Text(text)
            .font(.system(size: hero ? 30 : 26, weight: .bold))
            .tracking(hero ? -0.6 : 0)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .multilineTextAlignment(.center)
    }
}

private struct PageBody: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.primary.opacity(0.85))
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: OnboardingTokens.textWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: OnboardingTokens.textWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SkipButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary).underline(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// `.quaternary` group with hairline separators, like a compact grouped form.
private struct GroupBox<Content: View>: View {
    var width: CGFloat = 440
    var corner: CGFloat = 10
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - Page 0

private struct WelcomeBlock: View {
    @State private var app = AppModel.shared

    var body: some View {
        VStack(spacing: 10) {
            PageTitle(text: OnboardingStrings.welcomeTitle, hero: true)
            PageBody(text: OnboardingStrings.welcomeBody)
            StatusPill(color: pill.0, text: pill.1)
        }
    }

    private var pill: (Color, String) {
        if !app.hasRefreshed { return (.secondary, OnboardingStrings.welcomeStatusChecking) }
        if app.tailscaleMissing || app.status == nil { return (.red, OnboardingStrings.welcomeStatusMissing) }
        guard let s = app.status, s.running else { return (.orange, OnboardingStrings.welcomeStatusStopped) }
        return (.green, OnboardingStrings.welcomeStatusOK(s.tailnetName ?? "Tailnet", s.selfName))
    }
}

// MARK: - Page 0b

private struct TailscaleBlock: View {
    @Environment(OnboardingState.self) private var state
    @State private var app = AppModel.shared

    var body: some View {
        let installed = Tailnet.cliPath != nil
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if state.tailscaleConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 24))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PageTitle(text: state.tailscaleConnected ? OnboardingStrings.tailscaleConnectedTitle : OnboardingStrings.tailscaleTitle)
            }
            PageBody(text: bodyText)
            HStack(spacing: 8) {
                if !installed {
                    Button(OnboardingStrings.tailscaleDownload) {
                        NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(OnboardingStrings.tailscaleOpen) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.regular)
            .onHover { state.hoveringButton = $0 }
            Footnote(text: OnboardingStrings.tailscaleNote)
        }
    }

    private var bodyText: String {
        if state.tailscaleConnected, let s = app.status {
            return OnboardingStrings.tailscaleConnectedBody(s.selfName, s.tailnetName ?? "Tailnet")
        }
        return Tailnet.cliPath == nil ? OnboardingStrings.tailscaleBodyMissing : OnboardingStrings.tailscaleBodyStopped
    }
}

// MARK: - Page 1

private struct SendBlock: View {
    @Environment(OnboardingState.self) private var state

    var body: some View {
        VStack(spacing: 8) {
            PageTitle(text: OnboardingStrings.sendTitle)
            PageBody(text: OnboardingStrings.sendBody)
            Footnote(text: OnboardingStrings.sendNote)
            HStack(spacing: 10) {
                FileThumb(url: OnboardingMocks.tryIt, size: 28)
                Text(state.shelfOpened ? OnboardingStrings.sendTryDone : OnboardingStrings.sendTry)
                    .font(.system(size: 12, weight: state.shelfOpened ? .medium : .regular))
                    .lineLimit(1)
                if state.shelfOpened {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 16))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .overlay(DemoDragSource(url: OnboardingMocks.tryIt))
            .padding(.top, 4)
            .help("Zieh mich aus dem Fenster und schüttle den Cursor")
            if state.shelfOpened {
                Footnote(text: OnboardingStrings.sendTryHint).transition(.opacity)
            }
        }
    }
}

// MARK: - Page 2

private struct DevicesBlock: View {
    @Environment(OnboardingState.self) private var state
    @State private var app = AppModel.shared

    var body: some View {
        let online = app.devices.filter { !$0.viaTaildrop }.count
        VStack(spacing: 8) {
            PageTitle(text: OnboardingStrings.devicesTitle)
            PageBody(text: OnboardingStrings.devicesBody)
            HStack(spacing: 10) {
                Button {
                    OnboardingController.shared.copyInviteLink()
                } label: {
                    HStack(spacing: 5) {
                        if state.inviteCopied { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green) }
                        Text(state.inviteCopied ? OnboardingStrings.devicesInviteDone : OnboardingStrings.devicesInvite)
                    }
                    .frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .animation(.easeInOut(duration: 0.15), value: state.inviteCopied)
                Text(OnboardingStrings.devicesNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            Text(online > 0 ? OnboardingStrings.devicesOnline(online) : OnboardingStrings.devicesOnlineNone)
                .font(.system(size: 11))
                .foregroundStyle(online > 0 ? Color.green : Color.secondary)
        }
    }
}

// MARK: - Page 3

private struct ReceiveBlock: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 10) {
            PageTitle(text: OnboardingStrings.receiveTitle)
            PageBody(text: OnboardingStrings.receiveBody)
            GroupBox(width: 440) {
                HStack {
                    Text(OnboardingStrings.receiveAutoAccept).font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: $settings.autoAcceptOwnDevices).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                Divider().padding(.horizontal, 14)
                HStack(spacing: 8) {
                    Text(OnboardingStrings.receiveSaveIn).font(.system(size: 12))
                    Spacer()
                    Text(settings.downloadDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button(OnboardingStrings.receiveChange) { chooseFolder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
            }
            .padding(.top, 2)
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = settings.downloadDirectory
        p.prompt = "Wählen"
        if p.runModal() == .OK, let url = p.url { settings.downloadDirectory = url }
    }
}

// MARK: - Page 4

private struct ShortcutsBlock: View {
    var body: some View {
        VStack(spacing: 8) {
            PageTitle(text: OnboardingStrings.shortcutsTitle)
            PageBody(text: OnboardingStrings.shortcutsBody)
            VStack(spacing: 6) {
                row("keyboard", OnboardingStrings.shortcutHotkey) { KeyComboView(["⌃", "⌥", "⌘", "B"]) }
                row("doc.on.clipboard", OnboardingStrings.shortcutClipboard) { KeyComboView(["⌃", "⌥", "⌘", "V"]) }
                row("arrow.uturn.forward", OnboardingStrings.shortcutLast) { KeyComboView(["⌃", "⌥", "⌘", "L"]) }
                row("star", OnboardingStrings.shortcutFavorite) { KeyComboView(["⌃", "⌥", "⌘", "1–9"]) }
                row("hand.draw", OnboardingStrings.shortcutShake) { Chip(text: "Schütteln", symbol: "arrow.left.and.right") }
                row("square.and.arrow.up", OnboardingStrings.shortcutShare) { Chip(text: "Teilen", symbol: "square.and.arrow.up") }
            }
            .frame(width: 480)
            .padding(.top, 4)
            Footnote(text: OnboardingStrings.shortcutsChangeable).padding(.top, 2)
        }
    }

    private func row<T: View>(_ symbol: String, _ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(OnboardingTokens.brandGradient)
                .frame(width: 30)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            trailing().frame(width: 150, alignment: .leading)   // modifiers line up in columns
        }
        .frame(height: 26)
    }
}

// MARK: - Page 5

private struct ReadyBlock: View {
    @Environment(OnboardingState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 8) {
            PageTitle(text: OnboardingStrings.readyTitle)
            PageBody(text: OnboardingStrings.readyBody)
            GroupBox(width: 480, corner: 12) {
                SetupRow(symbol: "power", title: OnboardingStrings.readyLogin.0, subtitle: OnboardingStrings.readyLogin.1) {
                    Toggle("", isOn: $state.launchAtLoginWanted).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                Divider().padding(.horizontal, 14)
                SetupRow(symbol: "contextualmenu.and.cursorarrow", title: OnboardingStrings.readyQuickAction.0, subtitle: OnboardingStrings.readyQuickAction.1) {
                    if state.quickActionInstalled {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                            Text(OnboardingStrings.readyInstalled)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                    } else if OnboardingController.shared.quickActionInstaller != nil {
                        Button(OnboardingStrings.readyInstall) { OnboardingController.shared.installQuickAction() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Text(OnboardingStrings.readySoon).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 4)
            HStack(alignment: .top, spacing: 22) {
                summary(KeyComboView(["⌃", "⌥", "⌘", "B"]), "Shelf")
                summary(KeyComboView(["⌃", "⌥", "⌘", "V"]), "Zwischenablage")
                summary(KeyComboView(["⌃", "⌥", "⌘", "L"]), "Letztes Gerät")
                summary(Chip(text: "Schütteln", symbol: "arrow.left.and.right"), "Beim Ziehen")
            }
            .padding(.top, 6)
            Footnote(text: OnboardingStrings.readyNote).padding(.top, 2)
        }
    }

    private func summary<T: View>(_ control: T, _ caption: String) -> some View {
        VStack(spacing: 5) {
            control
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        }
    }
}
