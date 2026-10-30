# Open Source TV Remote

A free TV remote for iPhone, iPad and Mac. No subscriptions, ads, tracking or accounts: the app talks directly to your TV over your Wi-Fi.

Works with Google TV and Android TV (Sony, TCL, Hisense, Philips, Chromecast, Shield…), Roku, Samsung (Tizen) and LG (webOS).

- **Help:** see [SUPPORT.md](SUPPORT.md).
- **Privacy:** the app collects nothing. See [PRIVACY.md](PRIVACY.md).
- **Contributing:** see [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open OpenRemote.xcodeproj
```

Physical iOS builds need Apple's [Multicast Networking entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast) for Wake-on-LAN broadcast. Request it for your development team and app identifier, then regenerate the provisioning profile. Simulator builds do not verify this capability.

## License

[MIT](LICENSE)
