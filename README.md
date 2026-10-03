# Night Vision

Config-driven macOS display warmth, brightness, and MenuBarExtra controls.

## Install

Create `~/.config/night-vision/config.json` with a display backend (`ddc` or `internal`), ordered phases, and optional Shortcuts-backed lights, then run:

```sh
./install.sh
```

The installer installs the backend dependencies, compiles `nshift` and `NightVision.app` on the current machine, links `nightvision` into `~/.local/bin`, migrates legacy state, and replaces only the `com.aneyman.nightvision.*` launch agents. Run it again safely after configuration or source changes. Apps are always compiled locally; do not copy the ad-hoc signed app between machines.

## Schedule

Open **Schedule → Edit periods** in the menu bar app to choose a period, set its
start time, brightness, and warmth, then save it. **Use current settings** copies
the display's last read brightness and warmth into the selected period's editor;
**Save** stores that version for future transitions. Editing a period never
changes the display immediately. The Schedule switch enables or disables all
automatic phase jobs without changing the current display. Existing configs
default to enabled; `"scheduleEnabled": false` disables them for the day (the app stamps `scheduleOffOn`); the next day the schedule turns itself back on.

Changes are written atomically to `~/.config/night-vision/config.json` while
retaining other config fields, and the phase launch agents are refreshed without
reinstalling or rebuilding. For config edits made outside the app, run
`nightvision schedule-sync` to refresh their launchd times. Manual presets still
work while the schedule is off.

## Expanded brightness on built-in XDR displays

For the `internal` backend, Night Vision maps its existing 0-100 control across
one continuous range:

- 0-15: built-in backlight at minimum, then software dimming down to 2%
- 15-100: the full native backlight range

The 15 boundary is neutral, so phase presets, the menu slider, F1/F2,
and `nightvision lum` cross between software and hardware control without a
jump. `nightvision status-json` includes hardware, software/gamma, and mapping
readback under `brightness`. The menu app reapplies the selected state after
system gamma resets. This only targets an online built-in panel; external
displays keep their existing backend behavior.

High-brightness EDR is intentionally not advertised or mapped on Book. The M4
Max panel reports potential 5x EDR headroom, but macOS 26.5.2 kept current EDR
headroom at 1.0 for Night Vision's local Metal trigger. Applying gamma above 1.0
would therefore create an unverified, fictitious upper range. Native hardware
maximum remains 100%.

Run the focused mapping verifier with:

```bash
make test
```

## Keys

The menu bar app installs a session event tap for the top-row display keys:

| Key | Effect |
| --- | --- |
| `F1` / `F2` | Brightness down / up, 5% per press |
| `Shift-F1` / `Shift-F2` | Warmth down / up, 20% per press |
| `F1` + `F2` together, or `Option-F1` | Away: screen fully dark; any brightness key returns |

Both values clamp to 0-100. A press counts as a manual adjustment, so it holds
the schedule for the rest of the day the same way `lum`/`temp` do. Chords with
Command or Control pass straight through to the focused app.

Step sizes are configurable without a rebuild:

```json
"keySteps": { "brightness": 5, "warmth": 20 }
```

Brightness is instant over DDC, so small steps feel precise. Night Shift ramps
its color change over about a second, so warmth uses coarser steps.

The tap needs Accessibility. The app prompts on first launch and re-checks every
three seconds, so granting it takes effect without a relaunch. `build.sh` signs
with a stable local identity ("Apple Development: ...") when one exists, because
TCC pins the grant to the code signature and an ad-hoc signature changes on every
rebuild -- which silently revokes the grant and kills the keys.

To trace what the tap sees, `touch ~/.local/state/night-vision/keydebug`; the app
then logs display-key events to `~/.local/state/night-vision/keys.log`. Delete
the flag file to stop.

## Away

Press both brightness keys together (or Option + brightness down) to take the
screen fully dark without sleeping anything, so agents keep running: the display's hardware brightness
goes to 0 and the menu app holds every display's gamma at black. Press any
brightness key to come back; that press only restores the screen, it does not
also step the brightness. The menu's ⋯ button has the same "Away" action.

The CLI owns the hardware half and the flag file
`~/.local/state/night-vision/away`, which stores the brightness to restore.
The app watches that file, so `nightvision away` and `nightvision back` work
from ssh too. Phase jobs that run while away change warmth and appearance as
usual and record their brightness for the return instead of lighting the
screen. The app blacks out gamma only while its key tap is live, so a missing
Accessibility grant can never leave the screen black with no way back; if the
app quits, macOS drops the gamma and the screen is only as dim as brightness 0.

## CLI

```text
nightvision day|evening|winddown|cutoff
nightvision auto <phase>
nightvision sync
nightvision schedule-sync
nightvision lum <0-100>
nightvision temp <0-100>
nightvision away [level]|back
nightvision pause|resume
nightvision status|status-json
```

If the config is absent or invalid, the CLI and app use the built-in Studio phase defaults. State lives in `~/.local/state/night-vision`.

Each phase may set `"appearance": "light"` or `"appearance": "dark"`. Applying a phase disables macOS's competing automatic appearance schedule, applies that appearance, and verifies the resulting System Events state. For backward compatibility, a phase without this field uses Light for `day` and Dark for every other phase.

A manual `lum` or `temp` adjustment (the app's granular sliders and display-key controls use these) holds the schedule for the rest of the day, the same override "pause" uses, so phase jobs stop re-adjusting a hand-set brightness. The schedule resumes at the next morning day phase, or immediately when you pick a phase preset or run `resume`.

## Display keys

While the menu-bar app runs, it owns the display brightness keys globally:

- F1: brightness down 5 points
- F2: brightness up 5 points
- Shift-F1: warmth down 10 points
- Shift-F2: warmth up 10 points

Values clamp to 0...100. macOS may ask once for Accessibility permission so Night Vision can intercept these keys.
