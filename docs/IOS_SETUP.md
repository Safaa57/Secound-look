# iOS setup (one time, in Xcode)

iOS doesn't let any app read SMS or see incoming calls. Second Look uses the two official extension
points Apple provides instead. Both run the same on-device engine as Android.

| Feature | iOS extension | What it does |
|---|---|---|
| SMS Shield | Message Filter (IdentityLookup) | Messages from **unknown senders** are checked on the device. Scams go to the Junk folder, registered bank/OTP senders to Transactions, promotional senders to Promotions. |
| Call Shield | Call Directory (CallKit) | Numbers the user reported are blocked and labelled ("⚠ Second Look: Fake bank call"); trusted numbers are labelled. |

## Steps

1. Run `tool/setup.sh`, then open `ios/Runner.xcworkspace` in Xcode.
2. **App Group** (lets the app share the ON/OFF switches and reported numbers with the extensions)
   - Select the **Runner** target → Signing & Capabilities → + Capability → **App Groups** → add `group.com.secondlook.shared`.
   - If you change this name, change `SLShared.group` in `packages/secondlook_ios/ios/Classes/SecondLookPlugin.swift` and the two extension files.
3. **Message Filter extension**
   - File → New → Target → **Message Filter Extension**. Product name: `MessageFilter`. Bundle id must be `<app bundle id>.MessageFilter`.
   - Delete the generated `MessageFilterExtension.swift` and drag in `ios_extensions/MessageFilter/MessageFilterExtension.swift` and `ios_extensions/MessageFilter/secondlook_engine.js` (tick only the MessageFilter target).
   - Signing & Capabilities → add **App Groups** → `group.com.secondlook.shared`.
   - In the extension's Info.plist, remove `ILMessageFilterExtensionNetworkURL` if Xcode added it. Second Look never uses the network.
4. **Call Directory extension**
   - File → New → Target → **Call Directory Extension**. Product name: `CallDirectory`. Bundle id must be `<app bundle id>.CallDirectory`.
   - Replace the generated `CallDirectoryHandler.swift` with `ios_extensions/CallDirectory/CallDirectoryHandler.swift`.
   - Add **App Groups** → `group.com.secondlook.shared`.
5. Set the deployment target of all three targets to iOS 14.0 or later. Build and run on a real iPhone (extensions don't run in the Simulator's Messages app).
6. On the iPhone, the user switches the shields on in the app, then:
   - SMS: **Settings › Apps › Messages › Unknown & Spam › Second Look**
   - Calls: **Settings › Apps › Phone › Call Blocking & Identification › Second Look**
   The app shows these steps with an "Open Settings" button.

## What iOS doesn't allow (so we don't promise it)

- No pop-up when a scam SMS arrives. Messages from unknown senders are filtered silently into Junk.
- Messages from people in the user's Contacts are never given to any filter app.
- No live caller lookup in this version. iOS 18's *Live Caller ID Lookup* can show labels for any number in real time
  using Apple's private (homomorphic-encryption) lookup protocol. It needs Apple's approval and a PIR server, and it's the
  natural next step for Call Shield on iPhone.
