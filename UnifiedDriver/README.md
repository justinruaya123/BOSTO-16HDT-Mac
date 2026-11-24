# BostoTablet unified driver

An Apple Silicon-only arm64 app (`local.BostoTablet`) and one component package targeting
`/Applications/BostoTablet.app`. **Auto-detect tablet** is on by default:
launch and display changes select a unique nonmirrored Bosto Tablet display.
With auto-detect off, the app restores the manually chosen display by UUID.
Pen and touch start automatically when a safe display and the exact USB pen
and touchscreen are present and both macOS permissions are granted. The app
waits for late connections and resumes after wake or a session switch. It
tries each detected configuration once; a failed start does not loop.
Disable persists until explicitly enabled. Automatic startup never requests
permissions; use the setup button for missing grants.
**Touch orientation** offers Normal and Flip vertical, persists immediately,
and changes finger mapping only. Changing it during a gesture releases that
output and waits for lift without restarting the input session. Quitting,
disabling, an affected display change, sleep/session changes, permission loss,
or device failures release the owned streams. Optional Open at Login uses macOS 13+
SMAppService and follows the same startup rules. No launch
agent, install scripts, pen writes, Wacom
settings, mouse settings, or vendor executables are included.

## Scope and implementation

- `UnifiedPen.h`, `UnifiedPen.m`: strict report-1 parser and native event state
  machine. Only exact 8-byte report 1; flags bits 0–4, LE16 X/Y/pressure at 2/4/6,
  maxima `0x4600`, `0x2800`, `0x2000`. Reject reserved flags/out-of-range data.
  Hover uses mouse-moved events with tablet-point subtype. Tip uses native
  left-down/drag/up with tablet-point subtype and pressure. Proximity has matching
  device identity, pen/eraser pointer type and capabilities for X/Y/buttons/pressure.
  Barrel and secondary retain their native tablet button bits alongside optional, user-selected keyboard shortcuts.
  No tilt, rotation, smoothing or guessed protocol fields.
- `UnifiedMonitor.h`, `UnifiedMonitor.m`: unified implementation of the
  existing `BTPenMonitor` interface. Compile this **instead of**
  `Multitouch/BTPenMonitor.m`. Discovery is exact `0ED1:7821`, digitizer `13:2`;
  only the selected exact device is opened/seized, only while enabled. No pen
  feature reads or writes. Other report IDs are counted and ignored. Invalid
  report 1 fails closed. Stop emits tip up/proximity exit and closes even a failed
  open attempt. On startup, unknown proximity is reported honestly but does not
  block touch before the first accepted pen report.
  Direct device-removal and manager-removal callbacks both terminate the stream.
- `main.m`: controls, display selection shared by pen and touch, saved pressure sensitivity
  (exponent 0.25–4, default linear 1), touch resume delay (0–30 seconds, fresh default 2), status
  menu and JSON diagnostics. Delay is saved under this app's own defaults domain
  only after Enable; pressure and both shortcuts are saved in `local.BostoTablet`. No automatic permission requests
  until the user presses Enable. Permission grants are never reset or migrated.
- `Info.plist`, `components.plist`: app identity and nonrelocatable package metadata.
- `tests/test_controller.m`: existing offline hardware fixture checks the unified
  observe entry has zero device opens/writes/posts, touch silence cancels
  pending/drag/scroll/pinch input without closing, and genuine monitor failure
  closes both streams without an app delegate.
- `tests/test_pen.m`: offline parser and native CGEvent/AppKit checks. No posting.
- `tests/test_monitor.m`: fake HID/permission/posting checks for exact selection,
  failure cleanup, shared presence, and the real gesture core's two-second exit
  delay (repeated OUT packets do not restart it).
- `test.sh`, `build.sh`, `regression.sh`, `verify.sh`: local build and checks.

The reused `Multitouch/BT16Touch.c`, `BTGestures.c`, `BTTouchController.m`,
`BT16TouchEvents.m`, `BTGestureEvents.m` and their headers supply touch parsing,
first-finger pointer/tap/drag, two-finger scroll/pan and pinch, display handling,
palm rejection and cancellation. The replacement pen monitor publishes InRange
from the same packet that produces pen events, before pen events are posted.
Touch can start before the first pen packet; once the pen is confirmed nearby,
report silence does not end palm rejection. Following an observed exit, the
configured delay starts at exit; fingers resting through suppression must lift
before resuming.

The reused touch controller retains its existing exact `6066:0001` firmware
`[9,1,26]` gate and feature command `[3,0x0b,0]` when enabled. That command goes
only to the touch digitizer. Touch initialization failures release the pen too.
The reused controller calls the monitor snapshot `penObserver`; the UI corrects
its inherited top-level `penSeized` field using the unified monitor's actual
state. The old source comments about shared observation describe the old monitor,
not this replacement.

## Lifecycle safeguards

Unified HID disposal first marks the session stopping, invalidates its timer,
and blocks normal posting. Terminal releases and HID teardown run on the main
queue after the callback returns. Pending cleanup owns its context and buffer,
rejects restart until completion, and preserves the triggering status. App
termination waits for queued cleanup. Failure logs contain reasons, not raw
reports or coordinates. Standalone Multitouch disposal is unchanged.

The unified build defines `BT_UNIFIED_DRIVER=1`. Its touch controller rejects
`postEvents:NO` before HID discovery, opens, writes, or event posting, and handles
monitor failure by stopping both streams without depending on the app delegate.
Standalone Multitouch observation remains available in its separate build.

`UnifiedMonitor` uses monotonic `systemUptime` for a separate held-tip watchdog.
Only a posted tip-down arms it. At the first timer check with a gap of at least
2 seconds since the last successfully parsed and posted report 1, it logs the
gap and posts one tip-up, without a proximity exit, shortcut, session stop or
HID reopen. Held-tip reports remain suppressed until a real tip-up or out-of-range
report rearms the next stroke. Confirmed in-range presence continues to suppress
touch until the pen actually exits. Unrelated report IDs do not refresh this clock;
invalid report 1 still fails closed. Callback silence during hover or confirmed
out-of-range inactivity does not expire proximity or disable either stream. Snapshot fields
`heldTipReportTimeout`, `heldTipTimeouts`, `lastHeldTipTimeoutGap`, and
`lastValidReportUptime` expose this behavior for hardware validation and survive
stop (reset on the next start). This watchdog does not alter the distinct palm
cooldown. **The stationary-tip report gap and 2-second watchdog threshold have
not been physically validated.**

In BostoTablet, 0.5 seconds without a valid frame on the selected touch stream
cancels the stalled gesture once, without closing either HID connection. A lone
contact still needs a real lift before it can click again. A valid two-contact
frame can establish a new motion baseline immediately; scroll or pinch must
still cross the normal motion threshold, and never replays old movement or
presses. Pen suppression still requires lift and cannot use this recovery path.
Ordinary idle periods with no contacts leave touch ready. The standalone
Multitouch build retains its previous timeout behavior.

The pen protocol is restricted to exact `0ED1:7821 / 0D:02`, report 1.
Legacy `0ED1:782C` is unsupported: its bit packing and device behavior differ.
No legacy protocol implementation or old x86 binaries are reused.

## Build and inspect without live HID or GUI

Run from the repository root:

```sh
BT_LIVE_TESTS=0 bash UnifiedDriver/test.sh
BT_LIVE_TESTS=0 bash UnifiedDriver/regression.sh
bash UnifiedDriver/build.sh
bash UnifiedDriver/verify.sh
```

All generated outputs and compiler/package scratch stay under `build/unified*/`.
The regression script copies `Multitouch/` unchanged into
`build/unified-regression/Multitouch/`, verifies equality, then runs
`BT_LIVE_TESTS=0 bash Multitouch/test.sh` there. This confines the existing script's
hardcoded output path to `build/unified-regression/build/multitouch-tests/`.
Full regression output is `build/unified-regression/results.log`.

Deliverables: `build/unified/BostoTablet.app` and
`build/unified/BostoTablet.pkg`. The app is locally ad-hoc signed; the package is
unsigned. Packaging defaults to the source plist version; set the same validated
`BT_VERSION=MAJOR.MINOR.PATCH` for build and verification to override it.
`verify.sh` checks the expected app and package versions, signatures, arm64-only architecture, identity,
nonrelocatable `/Applications` installation, absence of scripts/extra payload,
and byte-for-byte equality of packaged and built app files. It executes only the
explicit offline `--self-check` path in both actual executables. This path does
not initialize AppKit UI, HID discovery, preferences, or event posting.

## Outstanding physical validation

Offline checks do not establish hardware or GUI behavior. Physically validate:

1. Real report delivery after exact seize, hover and enter/exit proximity, both
   side buttons and inversion, clean tip down/drag/up with pressure in drawing
   applications, and pressure curve behavior. Check stationary held-tip report
   gaps against the watchdog threshold, the logged timeout and one-time release,
   confirm silent hover remains in proximity, and verify up/out then a fresh stroke
   works without Enable. Native event construction and
   AppKit conversion checks do not establish actual application acceptance.
2. Pen suppression of active touch/scroll/pinch, two seconds **after** exit,
   adjustable delays, lift-to-resume, and preserved one-/two-finger behavior.
3. Selected display mapping (including Retina/negative origins), unplug/replug,
   display changes, sleep/session changes, permission revocation and re-enable,
   including interruption during an active pen stroke or gesture.
4. Package install to `/Applications/BostoTablet.app`, first-launch permissions
   under `local.BostoTablet`, local signature/Gatekeeper behavior and coexistence
   with other installed drivers.

There is no pressure/tilt claim beyond the descriptor fields. Pressure conversion
through AppKit mouse events has 8-bit quantization; the tablet pressure field is
also checked separately with its finer native quantization tolerance.

## Gesture settings

The **Gestures** tab offers **Default**, **Keyboard Shortcut**, and **Off**
separately for two-finger swipe and pinch. Default uses native horizontal and
vertical scroll events for pan/scroll and native magnify events for pinch.
A recorded key runs once per recognized gesture in the focused app. These
settings apply from the next gesture and don't replace single-finger taps,
drags, or palm rejection.

If gestures do not respond, check **reports with 2+ contacts** after a swipe.
A count of zero means no valid multi-contact frame was decoded in that session;
it does not by itself distinguish hardware, report acquisition, or parsing.
The event counters show what the driver posted, not what an app handled.

## Pen controls

Home / Setup keeps
its display, enable/disable, delay, status and diagnostics controls. Startup makes
one permission-gated attempt per detected configuration. Pen has a continuous
Softer–Linear–Firmer slider and Reset to linear.
Changes save immediately and update the running pen without reopening HID or
changing the display. `UPPressure` is the single mapping used by native outgoing
events and the live tester. The tester consumes only accepted exact pen packets,
refreshes at 4 Hz, and separates inactive, no data, out of range, tip up and tip
down; both pressure readings are zero while up/out/inactive. The raw scale is
0–8192 and the effective scale is 0–100%. No mouse pressure is sampled.

Buttons has one first-responder-only shortcut recorder and Clear / Unassigned
per physical side button. Both default to Unassigned. Optional Command, Shift,
Option and Control plus standard key codes are validated; modifier-only, media,
unknown codes and invalid persisted data are rejected. Escape cancels recording.
There is no keyboard monitor or tap. Each eligible rising edge creates a paired
key-down/key-up, with explicit modifiers only on key-down and zero on key-up;
no synthetic modifier keys are held. Held reports and release never repeat.
Initial held state and tool/proximity changes rebaseline the edge detector;
capture observes button state and configuration edits preserve known state. Invalid input and cleanup never run button actions.
Bindings apply across apps; no app profiles, calibration or offsets are included.

Preferences use `penPressureExponent` and `penShortcutBindings` in this app's own
domain. Invalid pressure falls back to linear; each invalid binding falls back
to Unassigned. Existing touch, palm cooldown, HID lifecycle and permission flows
are reused. `penObserver` diagnostics include `pressureState`, `rawPressure`,
`effectivePressure`, `sideButtonPresses` (per physical button), `shortcutPairs`,
`shortcutFailures` and `shortcutCapture`. Press counts exclude suppressed edges;
unassigned eligible presses still increment their physical counter. Counters
reset on Enable and survive stop for review.

Physical acceptance still requires checking pressure feel and tester agreement
in drawing apps, persistence across relaunch, side-button numbering and shortcuts
across apps, and suppression of repeats and held-at-enable or capture actions.
UI composition and layout also require manual validation, along with the
pointer/touch/palm/lifecycle/watchdog checks above.

Effective pressure is cached in the accepted report path with the curve used for
that packet's submitted native event. Moving the slider changes the curve for
future packets, without rewriting the tester's previous sample. Inactive/no-data,
tip-up and out-of-range values remain zero. The native pressure field has its
existing quantization; the monitor test compares with that tolerance.

Capture and binding edits preserve known side-button state. A known released
button fires on the next genuine press; a last-observed held button must release
before another press can fire. Capture continues observing reports without
emitting. Unknown initial state and tool/proximity transitions remain suppressed.
The monitor fixture records pressure and button transition transcripts for
offline validation.

The app icon is original tablet/stylus artwork generated offscreen from
`resources/GenerateIcon.m` using stock CoreGraphics, ImageIO and `iconutil`.
`build.sh` packages only `Contents/Resources/BostoTablet.icns` before signing;
`verify.sh` checks the resource allowlist and exact app/package bytes.
The fixed-width menu symbol is `!` when unavailable, a pencil during pen proximity
or palm cooldown, and a finger when the production gesture policy is ready.
Lift-required palm state remains unavailable until the policy clears it.

Pen battery is conditional: the Pen tab and menu show a percentage only if macOS
publishes a valid numeric integer `BatteryPercent` (0–100, excluding booleans) on
the already acquired exact 0ED1:7821 Digitizers 13:2 pen. Otherwise they show
“unavailable”. The read-only inspection of that exact pen found zero power
properties and no Digitizer Battery Strength (0x3B) in its 299-byte descriptor;
actual 16HDT battery telemetry and notifications have not been demonstrated.
No reports are guessed or probed. A valid reading below 20% can request native
notification consent once per launch and produce one alert per low streak;
20% or higher rearms it, while unknown readings preserve the latch. Consent
completion rereads the pen and suppresses alerts for unavailable/high readings.
