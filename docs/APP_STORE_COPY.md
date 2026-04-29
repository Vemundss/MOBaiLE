# App Store Copy Pack

This file is the copy pack for the current MOBaiLE App Store submission.

## Listing Metadata

- Name: `MOBaiLE`
- Subtitle: `Run tasks on your own machine`
- Promotional text:
  `Pair your Mac or Linux machine, send tasks by text or voice, and follow live progress from iPhone.`
- Keywords:
  `developer,remote,coding,terminal,voice,assistant,git,linux,mac,agent,repo,shell,tasks`

## Store Description

MOBaiLE turns your iPhone into a control surface for the Mac or Linux machine you already use.

Pair once with your own backend, send a prompt by text or voice, and watch the run progress in a live chat. Your host keeps the repo, shell, credentials, files, and network access. The phone stays focused on capture, follow-up, and recovery.

Use MOBaiLE to:
- Start repo checks, scripts, and coding-agent tasks away from the keyboard
- Keep progress, output, artifacts, and next steps in one readable thread
- Dictate quick tasks with voice mode and auto-send after silence
- Switch between workspace chats without losing context
- Inspect connection, runtime, and personal context settings when something needs attention

MOBaiLE is not a cloud IDE and does not run code on iPhone. It sends prompts, audio, attachments, and run metadata to the backend you choose to pair. The paired Mac or Linux machine does the execution.

## Screenshot Captions

1. `Run your own computer from iPhone`
   `Pair your Mac or Linux machine once, then start the next repo or terminal task from the phone.`
2. `Watch the run stay readable`
   `Progress, results, and follow-up stay together in one live thread.`
3. `Use voice when typing is awkward`
   `Dictate the next task, review the transcript, and keep voice mode attached to the current chat.`
4. `See access and context clearly`
   `Connection, executor, profile instructions, and memory controls stay explicit in settings.`
5. `Keep work split by thread`
   `Switch between workspace chats without losing the next step.`

## Public URLs

- Site: `https://vemundss.github.io/MOBaiLE/`
- Support: `https://vemundss.github.io/MOBaiLE/support.html`
- Privacy: `https://vemundss.github.io/MOBaiLE/privacy-policy.html`

## Review Notes

MOBaiLE is an iPhone control surface for a paired backend that runs on the user's own Mac or Linux machine. The app does not execute code on-device.

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
