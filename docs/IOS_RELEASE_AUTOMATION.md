# iOS Release Automation

This repo now includes a local Fastlane pipeline for preparing, building, and uploading iOS releases.

## What It Automates

- bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `ios/project.yml`
- regenerates `ios/VoiceAgentApp.xcodeproj` with `xcodegen`
- runs simulator tests before shipping unless you opt out
- archives the app for `app-store` export
- uploads builds to TestFlight or App Store Connect

The source of truth for iOS versioning stays in `ios/project.yml`.

## One-Time Setup

1. Install release tooling:

   ```bash
   npm run ios:release:setup
   ```

   The repo pins Fastlane `2.229.1` on purpose because newer Fastlane releases require Ruby `2.7+`, while the default macOS system Ruby on this machine is `2.6`.

2. Copy the environment template and fill in your values:

   ```bash
   cp fastlane/.env.example fastlane/.env
   ```

3. Set up Xcode signing once:
   - open `ios/VoiceAgentApp.xcodeproj`
   - assign your Apple team to `VoiceAgentApp` and `VoiceTaskWidgetExtension`
   - verify the bundle identifiers match the app record you own

4. Prefer App Store Connect API key auth for non-interactive uploads.
   - Set `APP_STORE_CONNECT_API_KEY_JSON_PATH` to a Fastlane JSON key file, or
   - set `APP_STORE_CONNECT_API_KEY_KEY_ID`, `APP_STORE_CONNECT_API_KEY_ISSUER_ID`, and `APP_STORE_CONNECT_API_KEY_PATH`

## Common Commands

Show the current app version/build:

```bash
npm run ios:version
```

Prepare the next build on the current marketing version:

```bash
npm run ios:release:prepare
```

Prepare a brand new App Store version. If the version changes and you do not pass a build number, the lane resets the build number to `1`:

```bash
npm run ios:release:prepare -- version:0.1.1
```

Build and upload a new TestFlight build:

```bash
npm run ios:release:testflight
```

Build and upload a new TestFlight build for a new version with release notes:

```bash
npm run ios:release:testflight -- version:0.1.1 changelog:"Bug fixes and polish"
```

Build and upload an App Store Connect release build without metadata/screenshots:

```bash
npm run ios:release:appstore -- version:0.1.1
```

Upload and immediately submit for review:

```bash
npm run ios:release:appstore -- version:0.1.1 submit_for_review:true automatic_release:false
```

## Lane Options

All Fastlane lane options are passed as `key:value` pairs after `--`.

Supported options on `prepare`, `beta`, and `release`:

- `version:0.1.1`
- `build:3`
- `skip_tests:true`
- `simulator:"iPhone 16 Pro"`

Extra options on `beta`:

- `changelog:"Bug fixes and polish"`
- `external:true`
- `groups:"Internal QA,External"`
- `skip_waiting:false`

Extra options on `release`:

- `skip_metadata:false`
- `skip_screenshots:false`
- `submit_for_review:true`
- `automatic_release:true`

## Practical Behavior

- If you keep the same marketing version, the lane increments the build number by one.
- If you pass a new marketing version and omit `build`, the lane starts that version at build `1`.
- `prepare` is the safe dry-run step before upload.
- `beta` is the main "push a new version to TestFlight" command.
- `release` uploads the binary to App Store Connect and can optionally submit it for review, but you still need your metadata, screenshots, privacy answers, and review notes to be correct.

## Caveats

- This setup assumes local Xcode signing is already working.
- Full CI-based signing automation is not included here. If you want fully headless GitHub Actions releases later, add certificate/provisioning management separately.
