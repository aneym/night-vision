# Night Vision

Config-driven macOS display warmth, brightness, and MenuBarExtra controls.

## Install

Create `~/.config/night-vision/config.json` with a display backend (`ddc` or `internal`), ordered phases, and optional Shortcuts-backed lights, then run:

```sh
./install.sh
```

The installer installs the backend dependencies, compiles `nshift` and `NightVision.app` on the current machine, links `nightvision` into `~/.local/bin`, migrates legacy state, and replaces only the `com.aneyman.nightvision.*` launch agents. Run it again safely after configuration or source changes. Apps are always compiled locally; do not copy the ad-hoc signed app between machines.

## CLI

```text
nightvision day|evening|winddown|cutoff
nightvision auto <phase>
nightvision sync
nightvision lum <0-100>
nightvision temp <0-100>
nightvision pause|resume
nightvision status|status-json
```

If the config is absent or invalid, the CLI and app use the built-in Studio phase defaults. State lives in `~/.local/state/night-vision`.
