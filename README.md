# Voice Dictate for iOS

Hold-to-talk dictation keyboard for iPhone: hold the pad, speak, release, and the cleaned-up text is inserted at the cursor.

> [!WARNING]
> **Sideload only. This app can never ship on the App Store.** It uses private API on purpose: `_UIRemoteKeyboards` and `LSApplicationWorkspace` (returning to the app you were typing in), the MediaRemote framework loaded via `dlopen` (pausing other audio while you talk), and `UIApplication.sharedApplication` looked up at runtime from the keyboard extension (keeping the screen awake). Each is looked up and checked at runtime, so a future iOS release can quietly disable any of them. Build it yourself and install it on your own device.

## What it is

Two parts, built from one Xcode project:

- **Companion app** (`VoiceDictate`): holds the microphone session, streams audio to OpenAI's realtime transcription API while you speak, sends the transcript to Anthropic's Messages API for cleanup, and keeps the API keys in its own Keychain. It also shows recent transcripts and lets you retry a failed recording.
- **Keyboard extension** (`DictationKeyboard`): a large record pad plus basic editing keys (delete with hold-to-repeat, space, return, globe when iOS doesn't show one). iOS doesn't let keyboard extensions record audio, so the keyboard sends commands to the companion through a shared App Group container and inserts the result.

The flow: activate the microphone once (the companion keeps it available for 5 minutes by default, or 15 minutes or 1 hour), then in any app hold the pad, speak, and release. Audio streams to OpenAI live during the hold; after release the transcript is cleaned up and inserted at the cursor. A separating space is added after a word or sentence; existing whitespace, selections and empty fields are left alone.

The settings (API keys, cleanup model and prompt, transcription model, vocabulary) are the ones from the macOS app [voice-dictate](https://github.com/chernov-anton/voice-dictate), imported once (see [Configuration](#configuration)).

## Requirements

- A Mac with Xcode 26 (developed with 26.3) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer (`brew install xcodegen`).
- An iPhone on iOS 17 or later (developed on iOS 26) with Developer Mode enabled (Settings > Privacy & Security > Developer Mode).
- An Apple account signed in to Xcode (Xcode > Settings > Accounts). A free Personal Team works. Its profiles expire after 7 days (see [Seven-day expiry](#seven-day-expiry-and-the-re-sign-agent)). A paid developer account gives one-year profiles.
- An OpenAI API key with realtime transcription access and an Anthropic API key.
- Full Access enabled for the keyboard. The keyboard needs it for the shared App Group container. The keyboard itself makes no network requests.
- Python 3 to export the configuration from the Mac app.

## Build and install

1. Configure signing. Copy the example and set your team ID and a reverse-DNS prefix you own:

   ```sh
   cp Local.xcconfig.example Local.xcconfig
   ```

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   VOICEDICTATE_ID_PREFIX = com.yourname
   ```

   This is the only place to set them. `VoiceDictate.xcconfig` holds the defaults and includes `Local.xcconfig` (git-ignored), so Xcode and `xcodebuild` both pick it up. Every identifier derives from the prefix:

   | | Identifier |
   |---|---|
   | App | `<prefix>.voicedictate.ios` |
   | Keyboard | `<prefix>.voicedictate.ios.keyboard` |
   | App Group | `group.<prefix>.voicedictate.ios` |

   Bundle IDs and App Groups are registered to the team that first uses them, so pick a prefix no one else has used; the default `com.example` is only for unsigned builds.

2. Generate the Xcode project (the `.xcodeproj` is not committed):

   ```sh
   xcodegen generate
   ```

3. Build and run on the phone. The first time, connect the iPhone, open `VoiceDictate.xcodeproj` in Xcode, select the `VoiceDictate` scheme and your iPhone, and press Run. Xcode registers the device, both app IDs and the App Group with your team. Then trust the developer certificate on the phone (Settings > General > VPN & Device Management). After that, the command line works too:

   ```sh
   xcrun devicectl list devices      # the Identifier column is <device-id>
   xcodebuild -project VoiceDictate.xcodeproj -scheme VoiceDictate -configuration Debug \
     -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
     -allowProvisioningUpdates build
   xcrun devicectl device install app --device <device-id> \
     build/DerivedData/Build/Products/Debug-iphoneos/VoiceDictate.app
   ```

   `-allowProvisioningUpdates` lets Xcode create or renew the profiles. `devicectl device install app` installs over the existing app and keeps its data.

4. On the phone: Settings > General > Keyboard > Keyboards > Add New Keyboard > Voice Dictate, then tap it and enable **Allow Full Access**.

An unsigned compile check, with no Apple account needed:

```sh
xcodebuild -project VoiceDictate.xcodeproj -scheme VoiceDictate -sdk iphoneos \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

## Configuration

The companion imports the configuration file of the macOS app ([voice-dictate](https://github.com/chernov-anton/voice-dictate), `~/.config/voice-dictate/config.json`). `export_configuration.py` copies the fields the phone uses into a new file with owner-only permissions. It never prints the values and refuses to overwrite an existing file:

```sh
python3 export_configuration.py ~/Desktop/voice-dictate-ios.json
```

Move the file to the phone (AirDrop to Files, for example), open the companion, tap **Import configuration…**, pick the file, then delete the file from the phone and the Mac. To update the settings, import again.

Without the Mac app, write the JSON by hand. `openAIApiKey`, `anthropicApiKey`, `cleanupModel`, `cleanupPrompt` and `cleanupMaxTokens` (1 to 32768) are required. `transcriptionModel` (default `gpt-transcribe`), `transcriptionPrompt` and `transcriptionKeywords` (an array of terms used as transcription hints and as a spelling reference during cleanup) are optional.

## Privacy

- **Audio goes to OpenAI** (`wss://api.openai.com/v1/realtime`), streamed while you hold the pad. Audio captured while the microphone is merely available is discarded, never uploaded.
- **Transcripts go to Anthropic** (`https://api.anthropic.com/v1/messages`) for cleanup.
- **API keys stay in the companion's Keychain** (this device only, not synced). The keyboard can't read them, and they are never compiled into the app. iOS can keep Keychain items after the app is deleted; to retire the keys, revoke them with OpenAI and Anthropic.
- Recording audio is kept in the companion's container only until the transcript is saved; it is deleted automatically after that. If transcription fails, the audio stays for a retry until you delete it (**Delete saved audio**) or record again. The companion also keeps a history of the last ten transcripts (raw and cleaned up); the app has no button to clear it, so deleting the app is the way to remove it. Diagnostic logs (see [Diagnostics](#diagnostics)) hold timings, audio-route and playback state, never audio or transcripts.
- There is no analytics or other server. The only network traffic is the two API calls above.

## Using it

- **Activate:** open the companion and tap the microphone button, or tap the activation link the keyboard shows when the microphone isn't available. The link opens the companion, activates, and switches back to your app (see [Automatic return](#automatic-return)). The in-app button doesn't switch back.
- **Dictate:** hold the pad while speaking and release to finish. One recording is limited to five minutes.
- **End Session** in the companion stops using the microphone. An audio interruption (a phone call, for example) also ends the session; activate again afterwards.
- If the keyboard is dismissed or the text field changes before the result arrives, the result isn't inserted automatically; the companion keeps it for recovery. If insertion may have happened twice, the companion says so.

## Seven-day expiry and the re-sign agent

With a free Personal Team, Xcode's provisioning profile expires seven days after the build. Then iOS refuses to launch the companion and stops launching the keyboard, without a message. To fix it, build and install again. Reinstalling over the top keeps the imported configuration and history; deleting the app first removes the history (the Keychain item may survive, but don't rely on that).

`scripts/voicedictate-ios-refresh` automates this from a Mac, and `scripts/install-refresh-agent.sh` installs it as a LaunchAgent that runs Monday to Friday at 10:00, 10:30, 11:00 and 11:30, hours when you are likely at the Mac and not dictating on the phone (at night the phone is often asleep and unreachable). A paid account (one-year profiles) doesn't need it.

```sh
xcrun devicectl list devices                                # find <device-id>
scripts/install-refresh-agent.sh --device <device-id>       # install or reinstall
scripts/install-refresh-agent.sh --print --device <device-id>   # show the plist only
scripts/install-refresh-agent.sh --uninstall
```

The agent's label is `<VOICEDICTATE_ID_PREFIX>.voicedictate.ios-refresh` (read from `Local.xcconfig`), and it runs the script from wherever this repository is checked out. Re-run the install command if you move the repository or change the phone.

What each run does:

- devicectl can't read the profile on the phone, so the script records the expiry of the last build it installed (the earlier of app and keyboard) in `~/Library/Application Support/voice-dictate/ios-refresh.json`. With no recorded expiry, the refresh counts as due.
- Nothing happens until the expiry is less than 100 hours away. Installing restarts the keyboard and kills the companion, and with it a dictation in progress, so installs happen only Monday to Friday between 10:00 and 12:00 local time, with no exceptions, not even for an expired profile. 100 hours guarantees at least two full weekday windows before every expiry (the reasoning is next to `REFRESH_WITHIN_HOURS` in the script). After a successful refresh the new profile has about seven days left, so the day's later runs skip. A run missed while the Mac slept happens on wake under the same rules.
- It checks that the iPhone is reachable (USB, or Wi-Fi after pairing). `devicectl list devices` only reports the last known state and shows a paired Wi-Fi phone as disconnected until something connects to it, so the script then connects with `devicectl device info details` (up to 30 s) before it gives up. Then it builds the committed `HEAD` of the current branch from a `git archive` copy plus your `Local.xcconfig` in `~/Library/Caches/voice-dictate/ios-refresh`. Uncommitted changes are never built. Set `VD_REFRESH_REF` to build another ref.
- If Xcode signs with a cached profile that is close to expiry, the script moves that profile to `stale-profiles/` in the cache directory and builds once more. A new build must be valid for at least 6 days. If that rebuild fails (for example Xcode is signed out: "No Accounts") or still isn't fresh, the moved profiles go back and the first build is installed instead, as long as it is valid for at least 24 more hours and outlasts the installed one; the log says so.
- It installs over the top (never uninstalls), confirms the app is listed on the phone, and records the new expiry.
- When a refresh is due inside the window and the iPhone is unreachable or locked, or the build or install fails, a LaunchAgent run (or a `--force` run from a terminal) shows a modal alert saying what to do (unlock the phone, connect it, sign in to Xcode > Settings > Accounts) and when the profile expires. Unlike a notification, Focus can't hide it. For a locked or unreachable phone it offers Retry, which reconnects and installs the build it already made, up to 3 times a run; Later, or no answer within 10 minutes, ends the run. At most one alert appears per hour (the time is kept in `ios-refresh-last-alert` next to the state file); other failures, and failures in plain manual runs, post a macOS notification instead. Notifications come from Script Editor, and macOS silences them while the display is shared or mirrored (screen sharing, or a streaming app such as Sunshine) unless System Settings > Notifications > "Allow notifications when mirroring or sharing the display" is on. The log always has the failure.

The Mac must be signed in to Xcode with the same Apple account, and the phone has to be reachable on weekday mornings. Runs that have nothing to install also check that Xcode still lists an account (`defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists`) and, if it is signed out, show the same alert (same hourly limit) so you can sign in before the re-sign is due; they never build because of it. Logs: `~/Library/Logs/voice-dictate-ios-refresh.log` (rotated at 512 KB), and the last `xcodebuild` output in `~/Library/Caches/voice-dictate/ios-refresh/build.log`.

Manual runs need the device in the environment:

```sh
export VD_REFRESH_DEVICE=<device-id>
scripts/voicedictate-ios-refresh --dry-run               # decide and print only
scripts/voicedictate-ios-refresh --force --no-install    # build now, don't touch the phone
scripts/voicedictate-ios-refresh --force                 # build and install now
scripts/voicedictate-ios-refresh --record <path/to/VoiceDictate.app>   # after a manual install
```

`--force` skips the expiry and install-window checks. The thresholds and the install window are variables at the top of the script.

## Known limitations

- **Activation needs the companion once per availability window.** A keyboard extension can't record audio or start the companion's audio session in the background. So after the window ends (5 minutes by default) or after an interruption, the next dictation starts with the activation link, which opens the companion briefly.
- **Automatic return uses private API.** If iOS changes `_UIRemoteKeyboards` or `LSApplicationWorkspace`, the companion shows "Microphone ready — swipe back to your app." and you switch back by hand.
- **Keeping the screen awake while holding may not work.** SpringBoard reads `idleTimerDisabled` from foreground app scenes, and a keyboard extension isn't one. If Auto-Lock fires during a long hold, the keyboard is dismissed and the recording stops.
- **Pausing other audio is best effort.** Since iOS 17.4, third-party apps can't read now-playing state, so the keyboard sometimes can't tell whether something was playing (see [Audio routing and other media](#audio-routing-and-other-media)).
- **Free accounts:** profiles last 7 days, and Apple limits how many app IDs a free team can register per week; this project uses two.
- Battery use with the microphone held open hasn't been measured.

## How it works

### Automatic return

After an activation from the keyboard's link succeeds, the companion reads the host app's bundle ID from UIKit's private `_UIRemoteKeyboards` state and opens that app through private `LSApplicationWorkspace`. The value lags the URL by up to about a second, so `HostReturnResolver` (Shared, unit-tested) ignores nil, stale and own-app values and gives up after 3 s. If no host is found or the open call fails, the status reads "Microphone ready — swipe back to your app." Outcomes (found, opened, elapsed time; never bundle IDs) go to os_log category `hostReturn`.

### Keyboard launch timing

The keyboard builds the SwiftUI activation link only when it has to show it. A cold launch with a live session goes straight to the record pad. The App Group is resolved off the main thread. Each keyboard process appends its first-appearance milestones (milliseconds since process start: `init`, `viewDidLoad`, first `layout`, `viewWillAppear`, `viewDidAppear`) as one JSON line to `Library/Caches/launch-timing.jsonl` in the keyboard's container.

### Screen awake while holding

A finger resting on the pad doesn't reset Auto-Lock, and locking dismisses the keyboard, which ends the hold. While the pad is held, the keyboard sets `idleTimerDisabled` on `UIApplication.sharedApplication`, looked up at runtime because it is unavailable to extensions at compile time. It clears the flag as soon as the hold ends for any reason. Each engage and release goes to os_log category `screenAwake` and to `Library/Caches/screen-awake.jsonl` in the keyboard's container (`event`, `cause` = touchUp/touchCancel/disappear/reset, `app`, `scenes`, `readback`, `heldFor` in seconds).

### Audio routing and other media

The companion's microphone session is `.playAndRecord` with `mixWithOthers`, `defaultToSpeaker` and `allowBluetoothA2DP` (policy and tests in Shared `MediaPausePolicy`). Other apps keep playing through the speaker or Bluetooth headphones while the microphone is available. Without `defaultToSpeaker`, iOS routes all audio to the earpiece for the whole window, so a video sounds silent. Bluetooth HFP stays off, so recording always uses the built-in microphone.

While the pad is held, other audio is paused and resumed on release, like system dictation, and only if this hold paused it. "Playing" means AVAudioSession's `isOtherAudioPlaying` (or MediaRemote's now-playing `isPlaying` if it answers). `secondaryAudioShouldBeSilencedHint` is logged but not used, because it reads true whenever the companion's microphone session is active. The steps, in order (Shared `MediaPausePolicy`/`MediaPause`, with tests; keyboard `OtherAudioPause`):

1. `keyboardRemote`: the keyboard sends Pause through the private MediaRemote framework (`MRMediaRemoteSendCommandWithReply`, loaded with dlopen/dlsym) and checks from 0.3 s to 0.8 s whether the audio stopped. Release sends Play. Unentitled clients can't address a specific app, but mediaremoted forwards their commands to the Now Playing app. Reading now-playing state needs entitlements third-party apps don't get (iOS 17.4, CVE-2024-23297), so `nowPlaying` in the log may read false, 0 or nil.
2. `companionRemote`: the same Pause sent from the companion, through `media-request.json`/`media-reply.json` in the App Group (the companion polls at 10 Hz). This covers a keyboard sandbox that blocks mediaremoted. It is skipped when the keyboard's command reached a handler, and when the companion isn't live. The companion acts on a request only within 0.5 s of its issue, checked again right before sending, so a late command can't land after the keyboard's 1 s wait. Release asks the companion for Play, waits up to 1 s for its reply, then sends Play from the keyboard. If the companion's microphone stops (End Session, interruption) while it owns a Pause, it keeps answering for up to 2 s under a background task.
3. `interrupt`, then `duck`, only while `isOtherAudioPlaying`: the keyboard activates its own play-only `.playback` session, non-mixable first, and deactivates it with `notifyOthersOnDeactivation` on release. This is the last resort: it can leave a Safari video playing silently, and Safari doesn't resume it.

If the audio stops after a Pause's check window but before a session step, the Pause took effect late, and release sends Play instead of interrupting. A Pause that a handler accepted while other audio kept playing (a second app) is also undone with Play, on top of the session step. That happens only if MediaRemote said the Now Playing app was playing before the hold; otherwise Play could start an idle app. An unanswered MediaRemote query counts as "still playing". Any end of a hold (release, cancel, dismissal, or the companion ending the recording) undoes what the hold did. The companion's microphone session is never touched, and failures are logged and ignored.

### SideStore

Xcode signs with the App Group as configured. SideStore re-signs it as `<group>.<TEAMID>` and suffixes the bundle IDs the same way. The shared resolver (`AppGroup`) reads each bundle's embedded provisioning profile and accepts exactly one group equal to `group.<prefix>.voicedictate.ios` or that plus `.<alphanumeric>`. Missing, malformed or ambiguous profiles fail closed. To build Xcode-signed IDs with a team suffix yourself, set `VOICEDICTATE_ID_SUFFIX = .<TEAMID>` in `Local.xcconfig`; the first build with a new suffixed group should run inside Xcode so the group gets registered. Keep SideStore's team-ID suffix enabled and don't edit the entitlements by hand. Real SideStore installs haven't been tested, and a separately signed copy needs its own configuration import.

## Diagnostics

The keyboard writes `launch-timing.jsonl`, `screen-awake.jsonl` and `media-pause.jsonl` to `Library/Caches` in its container. The companion writes `media-pause.jsonl` and `audio-session.jsonl` (activation with the output route, interruptions, route and engine configuration changes) to its own. Each file restarts past 64 KB. Each `media-pause.jsonl` line has a timestamp, step, `ok`/`error` (`errorName` gives the four-character code), `otherAudioPlaying`, `silenceSecondaryHint`, the route's port types, `nowPlaying` and `detail`. Fetch the files with devicectl, using the keyboard's or the companion's bundle ID:

```sh
xcrun devicectl device copy from --device <device-id> --domain-type appDataContainer \
  --domain-identifier <prefix>.voicedictate.ios.keyboard \
  --source Library/Caches/media-pause.jsonl --destination media-pause.jsonl
xcrun devicectl device copy from --device <device-id> --domain-type appDataContainer \
  --domain-identifier <prefix>.voicedictate.ios \
  --source Library/Caches/audio-session.jsonl --destination audio-session.jsonl
```

os_log messages use subsystem `voicedictate`, with categories `hostReturn`, `screenAwake` and `mediaPause`.

## Development

```sh
swift test --package-path Shared       # session, IPC, App Group, media-pause policy
swift test --package-path Core         # transcription and cleanup clients, config import
swift test --package-path Audio        # capture
bash scripts/tests/test-refresh.sh     # re-sign agent; every tool is stubbed, nothing reaches a phone or Apple
```

Layout: `App/` companion, `Keyboard/` extension, `Shared/` (both targets: session state, IPC, App Group), `Core/` (OpenAI and Anthropic clients, settings), `Audio/` (capture), `scripts/` and `launchd/` (re-sign agent). `project.yml` is the XcodeGen spec; the `Info.plist` and entitlements files are generated from it.

## License

[MIT](LICENSE)
