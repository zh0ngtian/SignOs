## How does it work?

SignOs retains Feather's server and pairing installation methods. Build, TLS configuration and distribution instructions live in [README.md](README.md#building).

To start off, we need a validly signed IPA. We can achieve this with Zsign, using a provided IPA using a `.p12` and `.mobileprovision` pair.

#### Install (Server)

- Use a locally hosted server for hosting the IPA files used for installation, including other assets such as icons, etc.
  - On iOS 18, we need a few entitlements: `Associated Domains`, `Custom Network Protocol`, `MDM Managed Associated Domains`, `Network Extensions`
- Fully Local requires a TLS certificate trusted by the device and a concrete hostname in `commonName.txt`. The app reads `server.crt`, `server.pem` and `commonName.txt` from Documents first, falling back to bundled resources. See README for the current local configuration; a wildcard certificate name is not a valid installation hostname.
- We then use `itms-services://?action=download-manifest&url=<PLIST_URL>` to attempt to initiate an install, by using `UIApplication.open`.

However, due to the changes with iOS 18 with entitlements we will need to provide an alternative way of installing. We have two options here, a way to install locally fully using the local server (the one I have just shown) or use an external HTTPS server that serves as our middle man for our `PLIST_URL`, while having the files still local to us. Lets show the latter.

- This time, lets not include https SSL certificates, rather just have a plain insecure local server.
- Instead of a locally hosting our `PLIST_URL`, we use [plistserver](https://github.com/nekohaxx/plistserver) to host a server online specifically for retrieving it. This still requires a valid HTTPS connection.
- Now, to even initiate the install (due to lack of entitlements from the former) we need to trick iOS into opening the `itms-services://` URL, we can do this by summoning a Safari webview to a locally hosted HTML page with a script to forcefully redirect us to that itms-services URL.

The current Semi Local implementation uses `https://api.palera.in/genPlist`, passing
the bundle identifier, name, version and local IPA URL as query parameters. It does
not upload the IPA. With **Only use localhost address** enabled, iOS fetches the
signed IPA from `http://127.0.0.1:<port>/…ipa` on the same phone. The remote service
only returns an HTTPS manifest and therefore does not need access to that loopback
address. This path was verified on iOS 27.0 with 2.7 MB and 183 MB source packages;
see [device verification and limitations](README.md#install-without-a-private-ca).
The remote manifest service must remain reachable, and system confirmation is
still required; automatic signing and prompting do not mean silent installation.

Opening `itms-services` requests an installation; it does not confirm success. Streaming progress only measures IPA delivery. OneView therefore keeps the signed archive actionable as Install until installation is confirmed, and server-based OTA retains the retry action.

#### Install (Pairing)
- Establish a heartbeat with a TCP provider (the app will need this for later).
  - For it to be successful, we need a pairing file from [PlumeImpactor](https://github.com/khcrysalis/Impactor?tab=readme-ov-file#pairing-file) and a [VPN](https://apps.apple.com/us/app/localdevvpn/id6755608044).
- Once we have these and the connection was successfully established, we can move on to the installation part.
  - Before installing, we need to check for the connection to the socket that has been created, routed to `10.7.0.1`, if this succeeds we're ready.
- When preparing for installation, we need to establish another connection but for `AFC` using the TCP provider.
- Once the connection was established we need to created a staging directory to `/PublicStaging/` and upload our IPA there.
- Then, using our connection to `AFC` we can command it to install that IPA directly. Similar to `ideviceinstaller`, but fully on your phone.

Due to how it works right now we need both a VPN and a lockdownd pairing file, this means you will need a computer for its initial setup. Though, if you don't want to do these you can just use the server way of installing instead (but at a cost of less reliability).
