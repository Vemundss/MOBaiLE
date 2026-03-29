# App Store Copy Pack

This file is the copy pack for the current MOBaiLE App Store submission.

## Listing Metadata

- Name: `MOBaiLE`
- Subtitle: `Your own computer, in your pocket`
- Promotional text:
  `Start work from iPhone, run it on your own Mac or Linux machine, and follow every step live.`
- Keywords:
  `developer,terminal,remote,voice,repo,coding,productivity,automation,assistant`

## Store Description

MOBaiLE is a handheld agent-control app for your own computer.

Pair the app with a backend running on your Mac or Linux machine, then send a text or voice request, keep it anchored to a working directory, and watch planning, execution, and results stream back live in one thread.

What you can do:
- Inspect a repo when you are away from the keyboard
- Run a smoke test and get the summary back in one place
- Dictate a task from your phone and send it hands-free
- Keep conversation history, run logs, and artifacts together
- Switch workspaces and keep future tasks pointed at the right folder

MOBaiLE is a client for a backend you configure and control. The app does not execute code on-device. It sends prompts, audio, attachments, and related metadata to the backend you pair with.

## Screenshot Captions

1. `Your computer, in your pocket`
   `Start a task from iPhone and keep every run anchored to your own machine.`
2. `Watch every run stream live`
   `Progress, summaries, and the next step stay in one thread instead of disappearing into a black box.`
3. `Capture voice tasks hands-free`
   `Record, review, and send with inline attachments, haptics, and auto-send after silence.`
4. `Dial in the setup once, then move`
   `Connection, voice, and support controls stay in one native settings sheet.`
5. `Keep work ready across threads`
   `Jump between active conversations without losing workspace context or the next follow-up.`

## Public URLs

- Site: `https://vemundss.github.io/MOBaiLE/`
- Support: `https://vemundss.github.io/MOBaiLE/support.html`
- Privacy: `https://vemundss.github.io/MOBaiLE/privacy-policy.html`

## Review Notes

MOBaiLE is an iPhone client for a paired backend that runs on the user's own machine. The app does not execute code on-device.

Review setup:
1. Open the app.
2. Go to Settings.
3. Enter Server URL: `<ADD_REVIEW_BACKEND_URL>`
4. Enter API Token: `<ADD_REVIEW_API_TOKEN>`
5. Keep Session ID as `iphone-app`.
6. Return to the main screen and send:
   `create a hello world python script and run it`

Expected behavior:
- the app sends the request to the paired backend
- progress appears in the conversation
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
