# Thump

Turns physical taps on your MacBook into instant, powerful actions. 

Thump uses your MacBook's built-in sensors to detect physical taps on the palm rest area. By double, triple, or quad-tapping, you can trigger instant actions like taking screenshots, controlling media, launching apps, or running custom shell scripts—all without lifting a finger off the chassis!

Built as a beautiful Droplet for [Droppy](https://getdroppy.app), Thump sits perfectly in your menu bar and dynamic island for seamless integration into macOS.

## Features

- **Custom Tap Sequences:** Trigger distinct actions for double, triple, and quad taps.
- **Auto-Calibration Wizard:** Thump comes with a gorgeous UI wizard to calibrate your exact tap strength and speed, creating a personalized threshold profile just for you.
- **Deep Action Integration:**
  - Launch Applications
  - Run Apple Shortcuts
  - Execute custom AppleScript & Shell Commands
  - Lock your Mac
  - Take instant Screenshots (with native shutter sounds!)
  - Native Media Controls (Play/Pause, Volume, Mute)
  - Native Screen Brightness Controls
- **Beautiful HUD:** Shows a live Dynamic Island / Notch Wing HUD confirming exactly how many taps were registered and which action was fired.

## Installation

You can install Thump directly from the [Droppy Store](https://getdroppy.app/droplets).

### Local Testing via Droppy Playground
If you'd like to test Thump locally before it's officially approved on the Droppy Store, you can use the [Droppy Playground](https://getdroppy.app/download/playground):

1. Clone this repository.
2. Build the droplet using DroppyKit: `droppykit build`
3. Copy the compiled bundle to your Playground Droplets folder:
   ```bash
   cp .build/Thump.droplet ~/Library/Application\ Support/Droppy\ Playground/Droplets/thump/Thump.droplet
   ```
4. Restart Droppy Playground, and Thump will appear in your Local Droplets!

## Requirements

- macOS 14.0 or newer
- Droppy 15.3.0 or newer
- A MacBook with a built-in accelerometer

## License

Thump is open-source software licensed under the MIT License. See the `LICENSE` file for more details.
