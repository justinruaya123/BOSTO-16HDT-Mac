# BostoTablet for macOS

BostoTablet is an Apple Silicon-only userspace driver for the exact Bosto
BT-16HDT interfaces below. `UnifiedDriver/` is the current app and package;
`Multitouch/` supplies its touch implementation and regression suite. The app
combines pen and touch controls, attempts permission-gated startup once for the
saved display or a unique nonmirrored Bosto Tablet display, and offers optional
Open at Login on macOS 13 and later.
Intel Macs and legacy binaries are outside this publication's scope.

## Device scope

Matching is restricted to these USB VID:PID and HID usage pairs. The model name
alone does not establish compatibility.

| Interface | VID:PID | Usage page:usage |
| --- | --- | --- |
| Pen | `0ED1:7821` | `0D:02` (digitizer pen) |
| Touch | `6066:0001` | `0D:04` (touch screen), `01:02` (mouse companion) |

Touch initialization additionally requires firmware bytes `[9,1,26]` before
sending `[3,0x0b,0]` to the touch digitizer. Other revisions, including pen PID
`782C`, are unsupported. These are implementation limits, not a claim of
validated hardware compatibility.

## Build or download

Download the latest stable release's [BostoTablet.pkg](https://github.com/justinruaya123/BOSTO-16HDT-Mac/releases/latest/download/BostoTablet.pkg)
and [SHA256SUMS](https://github.com/justinruaya123/BOSTO-16HDT-Mac/releases/latest/download/SHA256SUMS)
into the same directory, then verify before installing:

```sh
shasum -a 256 -c SHA256SUMS
```

On an Apple Silicon Mac with Xcode Command Line Tools available, run from the
repository root:

```sh
test "$(uname -m)" = arm64
BT_LIVE_TESTS=0 bash UnifiedDriver/test.sh
BT_LIVE_TESTS=0 bash UnifiedDriver/regression.sh
bash UnifiedDriver/build.sh
bash UnifiedDriver/verify.sh
(cd build/unified && shasum -a 256 BostoTablet.pkg > SHA256SUMS)
```

Outputs are `build/unified/BostoTablet.app` and `build/unified/BostoTablet.pkg`.
The app is ad hoc signed; the installer package is unsigned and neither is
notarized. No signing credentials are required.

Use the BostoTablet menu bar item’s **Check for Updates…** to check manually,
even before tablet permissions are granted. There are no background checks.
After confirmation, a newer stable package is size/SHA-256 verified against
GitHub’s asset metadata, saved without overwriting in a unique Downloads folder,
quarantined, and revealed in Finder. It is never opened or installed automatically.
Quit BostoTablet before opening the package in Installer; you may need to
reapprove Input Monitoring and Accessibility permissions. The package remains
unsigned and unnotarized, subject to macOS security checks.

For a CI build, open [Actions → macOS package](https://github.com/justinruaya123/BOSTO-16HDT-Mac/actions/workflows/macos.yml),
select a successful run for the intended commit, and download the
`BostoTablet-arm64` artifact. Extract it, then verify from that directory:

```sh
shasum -a 256 -c SHA256SUMS
```

The artifact contains only `BostoTablet.pkg` and `SHA256SUMS`. CI runs on pushes
to `main`, pull requests, and manual dispatch using GitHub-hosted arm64
`macos-15`. It runs offline tests, builds and verifies the package, and uploads
the artifact; it does not install the package.

Every successful trusted push to `main`, including a PR merge, automatically
publishes a stable patch release. The entire workflow is serialized for main
pushes using `queue: max`, without cancelling runs in progress. Pull requests
and manual dispatch use separate concurrency groups and only test, build,
verify, and upload artifacts. Tag pushes do not trigger publication.

Version selection uses fetched tags resolved to their actual commits. It takes
the highest canonical numeric `vMAJOR.MINOR.PATCH` tag and increments its patch;
prereleases and malformed tags are ignored. The source
`UnifiedDriver/Info.plist` version is a minimum for planned major/minor changes,
and is used directly when no stable tags exist. With latest tag `v0.1.3` and
source version `0.1.4`, the next release is `v0.1.4`. A rerun reuses the stable
tag already pointing to that commit, even if newer tags exist.

The selected version is stamped into the built app and package only; the tracked
plist is untouched. Local, PR, and manual builds default to the source version.
For an explicit local override, pass the same canonical version to both scripts:

```sh
BT_VERSION=0.2.0 bash UnifiedDriver/build.sh
BT_VERSION=0.2.0 bash UnifiedDriver/verify.sh
```

Only the separate release job has `contents: write`. Without checking out source,
it downloads that run's verified `BostoTablet-arm64` artifact, checks
`SHA256SUMS`, and creates the tag explicitly at the verified build commit if
absent. Existing lightweight or annotated tags must resolve to that exact
commit; conflicting or unresolvable tags fail publication and are never moved.
The job uses `gh release create --verify-tag` to publish a stable release marked
latest with the raw `BostoTablet.pkg` and `SHA256SUMS`, including the unsigned
installer warning. An existing release is left unchanged.

Release version policy tests are offline:

```sh
python3 -m unittest discover -s UnifiedDriver/tests -p test_version.py
```

## Permissions and validation limits

The package targets `/Applications/BostoTablet.app`. **Auto-detect tablet** is
on by default and selects a unique nonmirrored **Bosto Tablet**, even if a
manual display was previously saved. Turn it off to choose a display manually.
**Touch orientation → Flip vertical** reverses only finger-touch Y; choose
**Normal** to restore the original mapping. Both settings persist.
**Touch** and **Pen** are independent settings for the BT-16HDT. Both default to on. Leave the driver running to enforce the settings: turning both off mutes the display’s input; stopping the driver releases the hardware to macOS.

With Touch on, the driver leaves the Bosto companion interface (`01:02`) to macOS for native multitouch. With Touch off, the driver must identify and claim both the display’s digitizer and its own companion to block finger clicks, scrolling and pinch. This is a device-specific operation, not a macOS trackpad setting.

**Gestures** keeps native two-finger scroll/pan and pinch zoom by default.
Either gesture can run a recorded keyboard shortcut instead or be turned off.
The tab shows how many reports carried multiple contacts; those counts do not
prove an app received the resulting gesture.

BostoTablet starts pen and touch automatically when the selected display, exact
USB interfaces, and existing macOS permissions are ready. It also resumes on
reconnect or wake. **Stop driver (release tablet)** keeps the driver stopped until explicitly started again.
Automatic startup never prompts for permission; use the setup button for missing
Input Monitoring or Accessibility grants. Open at Login remains optional.

Touch works before the first pen report. Confirmed pen proximity pauses touch
for palm rejection; touch resumes after the configured delay and any resting
fingers lift. A gap in input reports does not disable either stream. Actual
system sleep or a user-session switch pauses input for safety until you return.
Unsigned/unnotarized distribution remains subject to macOS Gatekeeper checks.

CI does not launch the GUI, access live HID devices, post live input, install the
package, or change permissions. Offline tests and package verification do not
establish real-device behavior, drawing-app pressure or shortcut acceptance,
gesture routing, display mapping, lifecycle cleanup, or installer/first-launch
behavior. Physical validation is still required. See
[UnifiedDriver details](UnifiedDriver/README.md) for protocol, controls, and the
validation checklist, and [Multitouch details](Multitouch/README.md) for touch
protocol and regression instructions.

## License and reference

This publication retains the [GNU AGPL v3 license](LICENSE).
[georgejecook/BostoTabletDriverMac](https://github.com/georgejecook/BostoTabletDriverMac)
is acknowledged as an upstream reference. Its unlicensed legacy source and
history are not carried over here; no legacy binaries are included.

BostoTablet includes an original generated tablet/stylus app icon and a live
menu symbol for unavailable, pen/cooldown, and gesture-ready states. Pen battery
percentage and native low-battery alerts are conditional on macOS publishing a
valid `BatteryPercent` on the exact acquired pen; current 16HDT inspection found
no battery evidence, so “unavailable” is expected. See
[UnifiedDriver/README.md](UnifiedDriver/README.md) for the conditions and build details.
