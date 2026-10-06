#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import CoreFoundation
import Darwin
import Foundation
import LuminaLayout
import LuminaIPC
import os

extension AgentRuntime {
    // MARK: - Launch shield

    /// Hide a launching app until its first window is tiled, when its bundle
    /// is in `hide-until-tiled-apps`. Never called unless the user opted in.
    func shieldAppIfConfigured(pid: pid_t) {
        guard !isStopping(), !isOurProcess(pid) else { return }
        guard !shieldedOnce.contains(pid) else { return }
        guard let bundle = adapter.bundleId(pid: pid), config.hideUntilTiledApps.contains(bundle) else { return }
        guard shieldedPids.insert(pid).inserted else { return }
        shieldedOnce.insert(pid)
        let hidden = adapter.hide(pid: pid)
        let item = DispatchWorkItem { [weak self] in self?.unshield(pid: pid, reason: "timeout") }
        shieldTimeouts[pid] = item
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + shieldTimeout, execute: item)
        log.info("launch shield hide pid=\(pid) bundle=\(bundle) hidden=\(hidden)")
        if !hidden {
            // The app may not have checked in yet, where hide() is a no-op.
            // Retry briefly; the shield timeout still bounds it.
            for delay in [0.1, 0.3] {
                MutationQueue.shared.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.shieldedPids.contains(pid) else { return }
                    _ = self.adapter.hide(pid: pid)
                }
            }
        }
    }

    /// A crash or force-quit leaves a hide-until-tiled app hidden with no
    /// in-memory shield state to reveal it. Boot is the recovery point.
    func unhideShieldedAppsAtBoot() {
        guard !config.hideUntilTiledApps.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, config.hideUntilTiledApps.contains(bundle) else { continue }
            if app.isHidden {
                app.unhide()
                log.info("launch shield boot reveal pid=\(app.processIdentifier) bundle=\(bundle)")
            }
        }
    }

    /// Reveal a shielded app and schedule a settle pass; unhiding changes what
    /// CG lists on screen, and the app may repaint or reposition.
    func unshield(pid: pid_t, reason: String) {
        guard shieldedPids.remove(pid) != nil else { return }
        shieldTimeouts.removeValue(forKey: pid)?.cancel()
        pendingShieldReveal.remove(pid)
        adapter.unhide(pid: pid)
        // Focus follows the reveal only for a user-driven launch; a
        // launch-apps entry or a timeout reveal must not steal focus.
        if reason == "tiled", let bundle = adapter.bundleId(pid: pid), !config.launchApps.contains(bundle) {
            adapter.activate(pid: pid)
        }
        log.info("launch shield reveal pid=\(pid) reason=\(reason)")
        scheduleRefresh(reason: "shieldUnhide", delay: 0.05, eventDriven: false)
    }

    /// Forget a shield without revealing (the app is terminating or stopped).
    func dropShield(pid: pid_t) {
        shieldedPids.remove(pid)
        shieldedOnce.remove(pid)
        shieldTimeouts.removeValue(forKey: pid)?.cancel()
        pendingShieldReveal.remove(pid)
    }

    // MARK: - Launch watch

    /// Watch a just-launched pid with a bounded tight poll. All watch state is
    /// owned by `launchWatchQueue`; AX reads happen there and the result hops
    /// to the mutation queue.
    func startLaunchWatch(pid: pid_t, reason: String) {
        launchWatchQueue.async { [weak self] in
            guard let self, self.launchWatches[pid] == nil, !self.isOurProcess(pid) else { return }
            // Bound the concurrent pollers; the newest launches matter most.
            guard self.launchWatches.count < 6 else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.launchWatchQueue)
            timer.schedule(deadline: .now() + 0.02, repeating: self.launchWatchInterval, leeway: .milliseconds(2))
            self.launchWatches[pid] = LaunchWatch(timer: timer)
            self.log.debug("launch watch start pid=\(pid) reason=\(reason)")
            timer.setEventHandler { [weak self] in self?.launchWatchTick(pid: pid) }
            timer.resume()
        }
    }

    func cancelLaunchWatch(pid: pid_t) {
        launchWatchQueue.async { [weak self] in
            self?.launchWatches.removeValue(forKey: pid)?.timer?.cancel()
        }
    }

    func cancelAllLaunchWatches() {
        launchWatchQueue.async { [weak self] in
            guard let self else { return }
            for (_, watch) in self.launchWatches { watch.timer?.cancel() }
            self.launchWatches.removeAll()
        }
    }

    /// Runs on `launchWatchQueue`: only the adapter and pure helpers are
    /// touched, never the session.
    private func launchWatchTick(pid: pid_t) {
        guard var watch = launchWatches[pid] else { return }
        // Never poll while the agent is stopping, paused, or has no bound
        // display; the normal discovery paths resume on resume/reveal.
        guard !isStopping(), !userPaused, isCurrent, !displayGone else {
            launchWatches.removeValue(forKey: pid)?.timer?.cancel()
            return
        }
        // A background helper or updater never becomes a regular app; once it
        // has finished launching, drop the watch instead of polling for 2s.
        if let app = NSRunningApplication(processIdentifier: pid),
           app.isFinishedLaunching, app.activationPolicy != .regular
        {
            launchWatches.removeValue(forKey: pid)?.timer?.cancel()
            return
        }
        let elapsed = Date().timeIntervalSince(watch.startedAt)
        if elapsed > launchWatchMaxSeconds || kill(pid, 0) != 0 {
            launchWatches.removeValue(forKey: pid)?.timer?.cancel()
            return
        }
        watch.attempts += 1
        // Tight for the first frames, then a cheaper tail until the deadline.
        let phase = elapsed < launchWatchFirstPhaseSeconds ? 0 : 1
        if phase != watch.phase {
            watch.phase = phase
            watch.timer?.schedule(
                deadline: .now() + launchWatchSlowInterval,
                repeating: launchWatchSlowInterval,
                leeway: .milliseconds(5)
            )
        }
        launchWatches[pid] = watch
        guard let element = firstWindowElement(pid: pid) else { return }
        // A window exists. Stop polling and hand it to the mutation queue; if
        // the id is not resolvable yet, the fast retry ladder takes over.
        let id = adapter.windowIdIfKnown(for: element)
        let seenFrame = adapter.frame(of: element)
        nonisolated(unsafe) let token = Unmanaged.passRetained(element).toOpaque()
        let seenAfter = Int(elapsed * 1000)
        let attempts = watch.attempts
        launchWatches.removeValue(forKey: pid)?.timer?.cancel()
        MutationQueue.shared.hop { [weak self] in
            // Consume the retained element before any early return so the +1
            // from passRetained is always balanced.
            let element = Unmanaged<AXUIElement>.fromOpaque(token).takeRetainedValue()
            guard let self, !self.isStopping() else { return }
            if let id, self.ownedAnywhere(id) { return }
            let idText = id.map(String.init) ?? "?"
            let frameText = seenFrame.map { "\(Int($0.w))x\(Int($0.h))@\(Int($0.x)),\(Int($0.y))" } ?? "?"
            self.log.info("launch watch sighting pid=\(pid) id=\(idText) frame=\(frameText) after=\(seenAfter)ms attempts=\(attempts)")
            self.preParkNewWindow(element)
            // Hard preemption: a pending coalesced timer must not delay the
            // pass that adopts this window.
            self.refreshWorkItem?.cancel()
            self.refreshScheduled = false
            self.scheduleRefresh(reason: "launchWatch", delay: 0)
        }
    }

    /// First AXWindow element for a pid, if any. Runs on `launchWatchQueue`.
    private func firstWindowElement(pid: pid_t) -> AXUIElement? {
        // A resolvable window id is the signal. An element whose id is not
        // ready yet is retried on the next tick; a role read here could block
        // on the app's unchecked AX timeout and delay every other watcher.
        guard case .list(let elements) = adapter.enumerateWindows(pid: pid) else { return nil }
        for element in elements where adapter.windowIdIfKnown(for: element) != nil {
            return element
        }
        return nil
    }

    /// The earliest launch signal: macOS posts it as the app checks in, before
    /// its first window exists (the userInfo carries the NSRunningApplication,
    /// per the AppKit header contract for all application notifications).
    @objc func appWillLaunch(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        guard isCurrent, !userPaused, !displayGone, !isOurProcess(pid) else { return }
        if Thread.isMainThread {
            observers.watch(pid: pid)
        } else {
            DispatchQueue.main.async { self.observers.watch(pid: pid) }
        }
        MutationQueue.shared.hop { [weak self] in
            guard let self else { return }
            self.recentlyLaunchedPids[pid] = Date()
            self.launchPollsRemaining = max(self.launchPollsRemaining, 8)
            self.launchPollDelay = 0.25
            self.startLaunchWatch(pid: pid, reason: "willLaunch")
            self.shieldAppIfConfigured(pid: pid)
            self.scheduleRefresh(reason: "willLaunch")
        }
    }

    @objc func appLaunched(_ n: Notification) {
        guard isCurrent, !userPaused, !displayGone else { return }
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            let pid = app.processIdentifier
            // Watch on this turn, not one main-queue hop later: a window the
            // app creates during launch can otherwise outrun the observer and
            // force the slow poll ladder.
            if Thread.isMainThread {
                observers.watch(pid: pid)
            } else {
                DispatchQueue.main.async { self.observers.watch(pid: pid) }
            }
            MutationQueue.shared.hop { [weak self] in
                guard let self else { return }
                self.recentlyLaunchedPids[pid] = Date()
                self.launchPollsRemaining = max(self.launchPollsRemaining, 8)
                self.launchPollDelay = 0.25
                self.startLaunchWatch(pid: pid, reason: "appLaunched")
                self.shieldAppIfConfigured(pid: pid)
                self.scheduleRefresh(reason: "appLaunched")
            }
        }
    }

    @objc func appTerminated(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop {
                self.recentlyLaunchedPids[app.processIdentifier] = nil
                self.cancelLaunchWatch(pid: app.processIdentifier)
                self.dropShield(pid: app.processIdentifier)
                self.observers.unwatch(pid: app.processIdentifier)
                self.adapter.forgetAccessibility(pid: app.processIdentifier)
                self.dropPid(app.processIdentifier)
            }
        }
    }

    @objc func appHidden(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop {
                guard self.isCurrent, !self.userPaused, !self.ownedWindows(pid: app.processIdentifier).isEmpty else { return }
                // A shielded app is hidden on purpose until its window tiles.
                guard !self.shieldedPids.contains(app.processIdentifier) else { return }
                self.adapter.unhide(pid: app.processIdentifier)
            }
        }
    }

    @objc func appActivated(_ n: Notification) {
        guard !userPaused, isCurrent else { return }
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            // Insurance for a launch notification whose observer install
            // failed: activation is frequent and watch() is idempotent.
            observers.watch(pid: app.processIdentifier)
            MutationQueue.shared.hop {
                self.scheduleRefresh(reason: "appActivated")
                // Lay out the known tree before the refresh discovers the
                // activating app's window: siblings are settled when it
                // appears instead of shifting around it.
                self.applyFrames()
                if self.shieldedPids.contains(app.processIdentifier) { return }
                if self.ownedWindows(pid: app.processIdentifier).isEmpty {
                    self.launchPollsRemaining = max(self.launchPollsRemaining, 3)
                    self.launchPollDelay = 0.25
                    // Activation is usually too late to beat first paint, but
                    // for an app launched in the last few seconds it is still
                    // worth catching a late window in the first frames.
                    if let launchedAt = self.recentlyLaunchedPids[app.processIdentifier],
                       Date().timeIntervalSince(launchedAt) < 3
                    {
                        self.startLaunchWatch(pid: app.processIdentifier, reason: "appActivated")
                    }
                }
                // A model window may already be dead (Electron AX churn). A
                // space full of ghosts must not count as occupied, or macOS
                // promoting the next app after a close drags the user away.
                // An empty workspace is a valid place to be, so only the
                // predicate decides; it declines to follow without windows.
                let hasWindows = self.session.visibleIds(on: self.session.focusedSpace).contains { id in
                    guard let w = self.windowAnywhere(id) else { return false }
                    return self.hasAXElement(w)
                }
                // Drop superseded activations (the notification can arrive
                // after another app already took focus).
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                let elapsedSinceClose = Date().timeIntervalSince(self.lastWindowClosedAt)
                let elapsedSinceSpaceChange = Date().timeIntervalSince(self.lastLuminaSpaceChange)
                let isWindowCloseCascade = elapsedSinceClose < 0.4
                let shouldFollow = !isWindowCloseCascade && shouldFollowAppActivation(
                    spaceHasWindows: hasWindows,
                    elapsedSinceSpaceChange: elapsedSinceSpaceChange
                )
                guard shouldFollow else {
                    self.restashOffspace()
                    return
                }
                self.syncFocusToFrontmostApp(pid: app.processIdentifier)
            }
        }
    }
}
#endif
