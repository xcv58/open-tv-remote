# Remote Lab

An independent beta fork of [Open TV Remote](https://github.com/iamnbutler/open-tv-remote) by Nathan Butler, with an eyes-free joystick and Dynamic Island shortcuts. The iOS TestFlight app uses its own app identity and icon. No ads, analytics or tracking.

Works with Google TV and Android TV (Sony, TCL, Hisense, Philips, Chromecast, Shield…), Roku, Samsung (Tizen) and LG (webOS).

- **Help:** see [SUPPORT.md](SUPPORT.md).
- **Privacy:** TV control is local; saved settings can sync through iCloud. See [PRIVACY.md](PRIVACY.md).
- **Contributing:** see [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open OpenRemote.xcodeproj
```

## License

[MIT](LICENSE)
