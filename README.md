# build-frida-ios

Build a universal Frida package for jailbroken iOS devices, with a primary target of **iPhone 13 (A15) running iOS 16.6 in a standard rootless environment**.

The project builds Frida from source on a GitHub-hosted macOS runner or a local Mac, creates an external `frida-agent.dylib` containing both **arm64** and **arm64e** slices, packages the result as iOS DEB files, and verifies the generated Mach-O architectures.

> This repository contains build automation, not prebuilt Frida binaries.

## Why this project exists

Some Frida packages may start normally and enumerate applications, but fail when spawning or attaching to a process with an error such as:

```text
Failed to spawn: incompatible Mach-O image
```

One common cause is an Agent that does not contain the architecture required by the target process:

- third-party applications commonly run an `arm64` slice;
- Apple system processes may run an `arm64e` slice.

This project produces a universal Agent containing both:

```text
frida-agent.dylib
├── arm64
└── arm64e
```

It also follows the Frida 17.x external Agent layout:

```text
/usr/lib/frida-1.0/frida-agent.dylib
```

For a standard rootless jailbreak, the package is installed under `/var/jb`.

## Primary target

| Item                  | Target                  |
| --------------------- | ----------------------- |
| Device                | iPhone 13               |
| SoC                   | Apple A15               |
| iOS                   | 16.6                    |
| Frida                 | 17.16.4 by default      |
| Jailbreak layout      | Standard rootless       |
| Main DEB architecture | `iphoneos-arm64`        |
| Agent slices          | `arm64 arm64e`          |
| Signing during build  | Ad-hoc (`IOS_CERTID=-`) |

The version can be changed from the GitHub Actions input field, but this build kit is designed and checked primarily for the Frida 17.x layout.

## Repository layout

```text
build-frida-ios/
├── .github/
│   ├── scripts/
│   │   └── create-frida-cert.sh
│   └── workflows/
│       └── build-frida-ios.yml
├── build_frida_universal_ios.sh
├── verify_frida_package_macos.sh
├── install_rootless_usb.sh
├── README.md
├── README_zh.md
├── FIX_AGENT_INSTALL_PATH.md
├── FIX_IDENTITY_UNAVAILABLE.md
└── FIX_6H_CERT_HANG.md
```

The current workflow uses ad-hoc signing and does not call `create-frida-cert.sh`. The certificate script is retained only as an optional reference.

## Build without owning a Mac

GitHub Actions provides the required macOS, Xcode, iPhoneOS SDK, `lipo`, and `codesign` environment.

### 1. Create a GitHub repository

Create a new repository and upload all project files.

Make sure the hidden workflow path is preserved:

```text
.github/workflows/build-frida-ios.yml
```

Uploading only the visible files will not create the Actions workflow.

### 2. Run the workflow

Open:

```text
Actions
→ Build Frida 17.16.4 Universal iOS DEB v6
→ Run workflow
```

Keep the default version:

```text
17.16.4
```

The workflow performs these steps:

1. checks out the build kit;
2. selects Python 3.12;
3. verifies the macOS and Xcode environment;
4. installs GNU Make and `dpkg`;
5. verifies ad-hoc code signing;
6. clones the selected Frida tag;
7. builds the `ios-arm64e` target;
8. creates the universal server and Agent;
9. packages the DEB variants;
10. verifies the rootless package;
11. uploads the build artifacts.

### 3. Download the artifact

After a successful run, download:

```text
frida-17.16.4-iphone13-ios16.6-universal-debs
```

Expected contents:

```text
release-frida-17.16.4/
├── frida_17.16.4_iphoneos-arm64_universal.deb
├── frida_17.16.4_iphoneos-arm64e_universal.deb
├── frida_17.16.4_iphoneos-arm_universal.deb
├── BUILD-INFO.txt
└── SHA256SUMS
```

## Package selection

| Jailbreak layout                                            | Package                                       |
| ----------------------------------------------------------- | --------------------------------------------- |
| Standard rootless, including ordinary Dopamine-style layout | `frida_17.16.4_iphoneos-arm64_universal.deb`  |
| Rootful                                                     | `frida_17.16.4_iphoneos-arm_universal.deb`    |
| RootHide-style package architecture                         | `frida_17.16.4_iphoneos-arm64e_universal.deb` |

For an iPhone 13 using a normal rootless jailbreak, install the **`iphoneos-arm64`** package.

Do not select `iphoneos-arm64e` merely because the A15 supports arm64e. The DEB architecture identifies the jailbreak package-management layout, while the Agent inside the standard rootless package already contains both arm64 and arm64e Mach-O slices.

The standard rootless package is the primary supported and verified target of this build kit. Validate the generated `iphoneos-arm64e` package separately before using it in a RootHide deployment.

## Build locally on macOS

Requirements:

- macOS;
- full Xcode installation;
- initialized Xcode command-line environment;
- Python 3;
- Node.js;
- GNU Make;
- `dpkg`.

Example dependency setup:

```bash
xcode-select --install
brew install make dpkg node python@3.12

sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

Run the build:

```bash
chmod +x build_frida_universal_ios.sh
./build_frida_universal_ios.sh
```

Use a custom output directory:

```bash
./build_frida_universal_ios.sh \
  --output "$PWD/release-frida-17.16.4"
```

Keep the temporary source and build directory for debugging:

```bash
./build_frida_universal_ios.sh --keep-work
```

### Optional legacy arm64e OABI

The iPhone 13 on iOS 16.6 does not normally require the legacy arm64e ABI. The important compatibility change is an Agent containing both current `arm64` and `arm64e` slices.

To include the legacy arm64e OABI server slice:

```bash
export XCODE11=/Applications/Xcode-11.7.app

./build_frida_universal_ios.sh \
  --include-oabi
```

This requires Xcode 11.7 at the configured path.

## Verify the generated package

Run the verification script on macOS:

```bash
chmod +x verify_frida_package_macos.sh

./verify_frida_package_macos.sh \
  release-frida-17.16.4/frida_17.16.4_iphoneos-arm64_universal.deb
```

A successful result includes:

```text
Agent architectures: arm64 arm64e
PASS: universal agent contains arm64 and arm64e
```

You may also inspect the files manually after extracting the DEB:

```bash
mkdir -p /tmp/frida-check
dpkg-deb -x \
  frida_17.16.4_iphoneos-arm64_universal.deb \
  /tmp/frida-check

file /tmp/frida-check/var/jb/usr/sbin/frida-server
file /tmp/frida-check/var/jb/usr/lib/frida-1.0/frida-agent.dylib
lipo -archs \
  /tmp/frida-check/var/jb/usr/lib/frida-1.0/frida-agent.dylib
```

## Install on a standard rootless device

The expected rootless paths are:

```text
/var/jb/usr/sbin/frida-server
/var/jb/usr/lib/frida-1.0/frida-agent.dylib
/var/jb/Library/LaunchDaemons/re.frida.server.plist
```

### Option A: install through USB SSH forwarding

Start a USB SSH forward on the host:

```bash
iproxy 2222 22
```

In another terminal:

```bash
chmod +x install_rootless_usb.sh

./install_rootless_usb.sh \
  release-frida-17.16.4/frida_17.16.4_iphoneos-arm64_universal.deb
```

The script copies the DEB, installs it with `dpkg`, starts the launch daemon, and prints the device-side Frida version.

### Option B: install manually

Copy the package:

```bash
scp -P 2222 \
  frida_17.16.4_iphoneos-arm64_universal.deb \
  root@127.0.0.1:/var/mobile/
```

Connect to the device:

```bash
ssh -p 2222 root@127.0.0.1
```

Install and start Frida:

```bash
dpkg -i \
  /var/mobile/frida_17.16.4_iphoneos-arm64_universal.deb

launchctl kickstart -k system/re.frida.server
```

If dependency repair is required:

```bash
apt-get -f install -y

dpkg -i \
  /var/mobile/frida_17.16.4_iphoneos-arm64_universal.deb
```

Verify the installation:

```bash
/var/jb/usr/sbin/frida-server --version

ps aux | grep '[f]rida-server'

launchctl print system/re.frida.server
```

## Install a matching host client

The host-side Frida Python binding should match the server version.

Example on Linux or macOS:

```bash
python3 -m venv .venv-frida
source .venv-frida/bin/activate

python -m pip install --upgrade pip
python -m pip install \
  "frida==17.16.4" \
  frida-tools
```

Verify:

```bash
frida --version
frida-ls-devices
frida-ps -Uai
```

The host and device should both report:

```text
17.16.4
```

## Basic injection test

Create `basic-test.js`:

```javascript
console.log("Frida script is running");
console.log("PID:", Process.id);
console.log("Architecture:", Process.arch);
console.log("Platform:", Process.platform);
console.log("ObjC global:", typeof ObjC);
```

Run:

```bash
frida -U -f com.example.app -l basic-test.js
```

A result such as the following proves that the Agent was injected and JavaScript execution started:

```text
Frida script is running
Architecture: arm64
Platform: darwin
```

## Frida 17 and `ObjC is not defined`

Frida 17 moved the Objective-C bridge into the separate `frida-objc-bridge` package.

When a custom platform loads a raw script through an API such as:

```python
session.create_script(source)
```

the script may report:

```text
ReferenceError: ObjC is not defined
```

This is not an A15, AMFI, PAC, dyld, rootless, or Mach-O injection failure. It means the injected script did not bundle the Objective-C bridge.

Install and bundle the bridge on the host:

```bash
npm install frida-objc-bridge
```

Example TypeScript Agent:

```typescript
import ObjC from "frida-objc-bridge";

(globalThis as any).ObjC = ObjC;

console.log("ObjC available:", ObjC.available);
```

Compile it:

```bash
frida-compile agent.ts \
  -o agent.bundle.js \
  -S \
  -c
```

Then load `agent.bundle.js` instead of the original raw script.

## Troubleshooting

### `Failed to spawn: incompatible Mach-O image`

Verify the installed Agent:

```bash
file /var/jb/usr/lib/frida-1.0/frida-agent.dylib
```

It should be a universal Mach-O containing:

```text
arm64 arm64e
```

Also make sure an older Agent is not being loaded from:

```text
/var/jb/usr/lib/frida/frida-agent.dylib
```

### `frida-agent.dylib was not generated`

Frida 17.x installs the external Agent under:

```text
/usr/lib/frida-1.0/frida-agent.dylib
```

Older build scripts may incorrectly look under:

```text
/usr/lib/frida/frida-agent.dylib
```

The v6 build script uses the current `frida-1.0` path and includes a fallback for older tags.

### Code-signing identity is unavailable

The current workflow uses:

```text
IOS_CERTID=-
```

This performs ad-hoc signing while preserving the entitlements supplied by Frida's build process. It does not depend on a persistent Keychain identity.

### Workflow remains in the certificate step for hours

Use the current workflow. It does not create or trust a temporary `frida-cert`, avoiding unattended Keychain trust prompts on GitHub-hosted macOS runners.

### `frida-ps -Uai` works, but spawn or attach fails

Check:

- host/server version mismatch;
- an older Frida launch daemon still running;
- wrong DEB variant;
- stale Agent files;
- jailbreak spawn restrictions;
- target-process architecture;
- launch daemon status.

For a first diagnostic, open the application manually and attach by name or PID.

### `ObjC is not defined`

Injection already reached the JavaScript layer. Bundle `frida-objc-bridge`; do not rebuild the rootless server solely for this error.

### Frida server does not start after installation

Inspect:

```bash
launchctl print system/re.frida.server
ps aux | grep '[f]rida-server'
ls -l /var/jb/usr/sbin/frida-server
```

Restart:

```bash
launchctl kickstart -k system/re.frida.server
```

## Security and authorization

Use this project only on devices and applications that you own or are explicitly authorized to test.

Do not commit private signing keys, Apple certificates, provisioning profiles, SSH credentials, or device secrets to a public repository.

## Notes

- The build workflow uses a GitHub-hosted `macos-15` runner.
- Python 3.12 is selected to avoid accidental dependency issues from a newer runner-default Python.
- The build uses ad-hoc code signing for jailbreak-targeted packages.
- Artifact retention is configured for seven days.
- Existing Frida packages should be removed or backed up before replacing them.
- Keep a known-good SSH path to the device before changing the Frida launch daemon.

## License

This build kit does not change Frida's upstream license. Frida source code is cloned from the selected upstream tag during the build. Review and comply with the licenses of Frida and all included dependencies.
