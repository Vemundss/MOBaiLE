# App Store Copy Pack

This file is the copy pack for the current MOBaiLE App Store submission.

## Listing Metadata

- Name: `MOBaiLE`
- Subtitle: `Run tasks on your own machine`
- Promotional text:
  `Pair your Mac or Linux machine, send text or voice tasks, and follow live progress from iPhone.`
- Keywords:
  `developer,remote,coding,terminal,voice,assistant,git,linux,mac,agent`

## Store Description

MOBaiLE lets you start and follow developer tasks on a paired Mac or Linux machine from your iPhone.

Send a text or voice request, keep it tied to the right workspace, and see live progress, results, and follow-ups in one chat.

What you can do:
- Kick off repo checks and smoke tests when you are away from the keyboard
- Watch live activity and final output in the same conversation
- Send voice tasks hands-free and auto-send after a short pause
- Keep separate chats anchored to the right workspace
- Reconnect, retry, or inspect run details when something needs attention

MOBaiLE is a client for a backend you configure and control. The app does not execute code on-device. It sends prompts, audio, attachments, and related metadata to the backend you pair with.

## Screenshot Captions

1. `Run tasks on your own computer`
   `Pair your Mac or Linux machine once, then send the next task from iPhone.`
2. `See live progress in one chat`
   `The run, the next step, and the final result stay in the same conversation.`
3. `Send voice tasks hands-free`
   `Speak the request, add context, and auto-send after a short pause.`
4. `Tune connection and runtime in-app`
   `Backend, voice, appearance, and runtime controls stay in one native settings sheet.`
5. `Keep every task in the right chat`
   `Switch between active workspaces without losing context or the next follow-up.`

## Public URLs

- Site: `https://vemundss.github.io/MOBaiLE/`
- Support: `https://vemundss.github.io/MOBaiLE/support.html`
- Privacy: `https://vemundss.github.io/MOBaiLE/privacy-policy.html`

## Review Notes

MOBaiLE is an iPhone client for a paired backend that runs on the user's own machine. The app does not execute code on-device.

Basic review:
1. Open the app and inspect onboarding, settings, thread list, and voice/chat UI.
2. Microphone access is optional and only needed for voice input.
3. Local-network access is only used when the paired backend is on the same network.

Functional review:
1. Open the app.
2. Go to Settings.
3. Enter the review backend URL and API token supplied for App Review.
4. Keep Session ID as `iphone-app`.
5. Return to the main screen and send:
   `map the repo and summarize the current workspace`

Expected behavior:
- the app sends the request to the paired backend
- live progress appears in the conversation
- a final summary is returned in the same thread

## Claims To Avoid

- Do not claim the app executes code on the iPhone.
- Do not claim unattended or unrestricted control of the user's machine.
- Do not imply internet-wide remote access without the backend/network setup the user chooses.
- Do not promise capabilities the configured backend does not provide.

## Privacy / Functionality Summary

- Stores local connection settings and thread state on-device.
- Sends prompts, voice input, attachments, and run metadata to the backend selected by the user.
- Uses local Speech Recognition when available, with backend transcription fallback when configured.
- Public support and privacy pages are already published and reachable.
