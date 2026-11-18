# Bosto BT-16HDT: Multitouch dependency and regression suite

`UnifiedDriver/` is the current BostoTablet product and reuses the touch parser,
gesture policy, controller, and event code here. This directory also retains a
standalone Apple Silicon development app and regression suite. Its standalone
pen observer uses a shared, read-only connection; the unified driver replaces
that observer with its own pen implementation. The instructions below describe
the standalone app, not the unified package.

## Build and use

```sh
BT_LIVE_TESTS=0 bash Multitouch/test.sh
bash Multitouch/build.sh
```

The build creates `build/multitouch/Bosto Multitouch.app`, signed ad hoc with its own bundle identifier, `local.BostoMultitouch`. Building and running the offline tests do not launch it. The offline suite replaces HID access, permission checks, defaults persistence, and event posting at their boundaries. Native event tests create and decode events without posting them. Leave `BT_LIVE_TESTS` at `0` for offline work.

For a physical test, open the standalone app manually. The app starts **disabled**, defaults to the named Bosto display, and includes a test pad for taps, dragging, two-finger pan and pinch. Press **Enable finger touch** when ready. If needed, manually grant this app **Input Monitoring** and **Accessibility**, then retry Enable. The existing firmware-guarded touch initializer runs only when enabling event posting; observation mode makes no configuration writes.

One finger taps or drags after a short arming interval. Two fingers select precise pixel scrolling/panning or native magnification from their initial motion and keep that gesture until release. Scroll and magnify output includes begin/change/end or cancel phases. Three or more contacts cancel output until all fingers lift.

Pen InRange or genuinely unavailable/invalid proximity cancels and suppresses touch. After a detected pen leaves, touch resumes after **2 seconds** by default. **Resume touch after pen leaves** accepts 0–30 seconds; press Return or **Save delay** to persist it for the next launch. Changing the delay keeps the original pen-exit time. Resting fingers must lift before a fresh gesture can start. An initially valid out-of-range pen does not incur a startup delay. If the exact shared pen observer cannot start, touch capture is closed; Enable reports the error.

Click **Disable finger touch**, or use the menu-bar menu to stop/quit. The helper does not auto-start. Stop, touch disconnect, sleep/session change, display change, permission revocation, and a 0.5-second missing-report timeout cancel active output and close both connections. The timeout also covers pending/suppressed contacts. HID callbacks and the watchdog use common run-loop modes so UI tracking does not starve reports. If the target disappears, there is **no automatic fallback to the Retina display**.

## Diagnostics

```sh
APP="build/multitouch/Bosto Multitouch.app/Contents/MacOS/BostoMultitouch"
"$APP" --diagnose       # metadata/permissions only; never opens the hardware
"$APP" --observe 20     # live touch capture + shared pen observation; no writes or input posting
"$APP" --run 20         # live firmware-guarded touch initialization and gesture posting
```

These diagnostics access the local device and permissions; they are not CI checks. Both bounded modes close device access on completion. SIGINT and SIGTERM leave the run loop through normal cleanup, cancel active output, and return the conventional signal exit code. `--observe`/`--run` return 3 if no valid touch frames arrive or a device/permission failure stops the interval. The app's permissions may differ from a terminal's permissions.

## Protocol and tests

Touch matching stays exact: USB `0x6066:0x0001`, digitizer `0x0d:0x04` plus mouse companion `0x01:0x02`. The pen is excluded from this exclusive manager. The shared observer matches only `0x0ed1:0x7821`, digitizer `0x0d:0x02`, report 1's one-bit InRange (`0x32`) input; its initial read requests the cached value without update.

The baseline parser is unchanged: six-byte vendor report3 (pressed bit 7, LE16 X/Y), or complete 64-byte report4 (ten five-byte slots, low six ID bits, pressed bit 6, LE16 X/Y, count byte 55). Report3 remains available for single-finger-only streams. A duplicate report4 with one contact does not interrupt an active report3 gesture. Two contacts in report4 cancel the report3 interaction and promote immediately; after report4 has shown real contacts, subsequent gestures prefer report4. Ignored duplicates never refresh the active stream's watchdog or lift its contacts.

Advertised logical range is X 0–16384, Y 0–9600. Coordinates map to `CGDisplayBounds` in Quartz **logical** space, including extended displays with negative origins.

`fixtures/real-touch-capture.json` contains 32 captured touch packets, USB hardware IDs, and capture counts for offline replay. The suite includes replay and baseline pointer tests. The runner also exercises the pure gesture policy, native AppKit event interpretation, shared pen observer, controller lifecycle/report dispatch, and CLI signal cleanup. Edge cases use explicitly synthetic fixtures. The suite uses UBSan plus bounds instrumentation.

Physical validation remains necessary for simultaneous report3/report4 ordering, actual two-finger contacts, pan direction and precision, native pinch behavior/routing in target apps, pen-driver coexistence and proximity transitions, UI layout/persistence, and cleanup during real disconnection, permission changes, sleep and tracking loops. Native pinch uses undocumented recognized-gesture fields; successful AppKit decoding does not prove that every target application accepts posted gestures.
