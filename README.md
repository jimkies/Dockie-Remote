# Dockie Remote

An iPhone companion for [Dockie](https://github.com/jimkies/dockie), the Windows Roblox multi-account launcher. Pair with Dockie on your PC, see every account's window at a glance, and open a temporary full-screen share of one.

Dockie Remote only watches. It never asks for Roblox credentials and only sends the protocol messages listed in [docs/design.md](docs/design.md).

Requirements: iOS 17 or later, a Mac with Xcode 16 or later, and Dockie running on your PC with Remote turned on.

## Generate the Xcode project

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). There is no `.xcodeproj` in the repo.

```sh
brew install xcodegen
xcodegen generate
open DockieRemote.xcodeproj
```

Run `xcodegen generate` again whenever you pull changes that add or remove files.

## Build and install with a free Apple ID

1. In Xcode, go to Settings > Accounts and add your Apple ID.
2. Select the DockieRemote target, open Signing & Capabilities, and choose your Personal Team.
3. Change the bundle identifier from `com.example.dockie.remote` to something unique, like `com.yourname.dockie.remote`. A free team can't use an identifier someone else has registered.
4. Plug in your iPhone, unlock it, and pick it as the run destination. Turn on Developer Mode on the phone if asked (Settings > Privacy & Security > Developer Mode, then restart).
5. Press Run. The first time, the phone will refuse to open the app. Go to Settings > General > VPN & Device Management, tap your Apple ID, and tap Trust.

Apps signed by a free Apple ID stop opening after 7 days. When that happens, plug the phone in and press Run again in Xcode. Your pairing is kept in the Keychain, so you won't need to pair again.

The app uses no capabilities that need a paid developer account: no push notifications and no background modes.

To run the unit tests, choose Product > Test (Cmd-U) with an iPhone simulator selected.

## First launch

1. In Dockie on your PC, open Remote. It shows a QR code.
2. In Dockie Remote, tap Scan QR code and allow camera access.
3. iOS will ask to let Dockie Remote find devices on your local network. Tap Allow. Without it the app can't see or reach your PC.

If you tapped Don't Allow, turn it on in Settings > Privacy & Security > Local Network > Dockie Remote.

You can also pair without the camera: pick your PC under "PCs on this network" and paste the pairing token from Dockie.

If Dockie resets its pairing, the app returns to the Pair screen with "Pairing was reset on the PC". Scan the new code.

Tip: give your PC a reserved IP address in your router (DHCP reservation). The QR code stores the PC's current address, so if the router hands it a new one, you'll have to pair again.

## Connecting from outside home with Tailscale

1. Install [Tailscale](https://tailscale.com) on the PC and on the iPhone, and sign in to the same account on both.
2. In the Tailscale app on the PC, copy the PC's Tailscale IP. It starts with `100.`.
3. In Dockie Remote, open Settings and enter that IP as the Away address. Use the IP, not the `.ts.net` name: the app's network security settings only allow plain WebSocket connections to private and Tailscale IP ranges.
4. Keep Tailscale connected on the phone while you're away.

Dockie Remote tries the home address first and then the away address, so it works in both places without switching anything. If Windows Firewall asks about Dockie, allow it on private networks; Tailscale traffic arrives on the Tailscale adapter.

## Good to know

The app disconnects when you leave it and reconnects when you come back. Shares stop when you leave, too.

Over your home Wi-Fi the connection is plain `ws://`, so someone else on the same Wi-Fi could read the pairing token. Over Tailscale it's encrypted. If you think the token leaked, reset the pairing in Dockie and pair again.

## Project layout

```
project.yml                  XcodeGen spec, including Info.plist keys and ATS exceptions
DockieRemote/Protocol        Protocol v1 messages and the pairing payload
DockieRemote/Connection      Connection state machine, WebSocket, frame decoder, app store
DockieRemote/Pairing         Keychain, Bonjour browser, QR scanner
DockieRemote/Screens         Pair, accounts grid, share view, settings
DockieRemote/UI              Theme and shared components
DockieRemoteTests            Unit tests for the protocol and the state machine
docs/design.md               Design and protocol notes
```
