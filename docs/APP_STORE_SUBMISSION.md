# App Store Submission Checklist

This repo is now in better shape for App Store submission, but a few steps still have to happen in Xcode and App Store Connect.

## Repo-Level Checks Already Landed

- `MOBaiLE` is now the shipped display name in the iOS target.
- Broad ATS has been removed in favor of local-network access only.
- A privacy manifest is included for the app's `UserDefaults` access.
- A real `AppIcon` asset catalog is present and wired into the build.
- The app and widget now use build settings for version metadata.
- Simulator tests pass.
- A release iOS device build passes with `CODE_SIGNING_ALLOWED=NO`.

## Remaining Xcode Steps

1. Open `ios/VoiceAgentApp.xcodeproj` in Xcode.
2. Set your Apple team on both `VoiceAgentApp` and `VoiceTaskWidgetExtension`.
3. Replace bundle identifiers with production values you control.
4. Decide the first App Store version string and build number.
5. Archive from Xcode:
   `Product` -> `Archive`
6. Validate the archive before upload.

## App Store Connect Work You Still Need

1. Create the app record with the final bundle identifier.
2. Fill in the app name, subtitle, description, keywords, support URL, and marketing URL.
3. Provide a stable privacy policy URL.
4. Upload iPhone screenshots for the device classes App Store Connect asks for.
5. Complete App Privacy answers based on what your production backend stores or transmits.
6. Complete export compliance. With the current app target, `ITSAppUsesNonExemptEncryption` is set to `false`, but you still need to answer App Store Connect's questions.
7. Upload the archive and submit the selected build to App Review.

## Review Notes You Should Prepare

This app depends on a user-paired backend, so review notes matter.

- Provide a reviewer backend that is reachable without Tailscale account setup friction.
- Prefer an HTTPS review backend for App Review.
- Include exact pairing steps.
- Include one or two prompts the reviewer can run successfully.
- Explain that the app is a client for the user's own paired backend and does not execute code on-device.

Suggested review note template:

```text
MOBaiLE connects to a paired personal backend that runs on the user's own machine.

Review setup:
1. Open the app.
2. Go to Settings.
3. Enter Server URL: <review backend url>
4. Enter API Token: <review token>
5. Keep Session ID as the default value.
6. Tap "Check backend".

Suggested test prompt:
"create a hello world python script and run it"

Expected behavior:
- the app sends the request to the paired backend
- progress appears in the conversation
- a final summary is returned in the chat view
```

## Before You Hit Submit

- Replace the generated icon set with final production artwork if you have a higher-resolution source than `ios/VoiceAgentApp/mobaile_logo.png`.
- Confirm your privacy policy and support URLs are not temporary placeholders.
- Test pairing and one complete run on a real iPhone using the exact build you plan to upload.
