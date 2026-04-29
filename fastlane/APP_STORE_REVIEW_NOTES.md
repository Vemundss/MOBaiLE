# App Store Review Notes

## Reviewer Summary

MOBaiLE is an iPhone control surface for a paired personal backend that runs on the user's own Mac or Linux machine.
The app does not execute code on-device. It sends prompts, optional audio, attachments, and run metadata to the configured backend, then displays live progress and returned results.

## Suggested Review Steps

1. Open the app.
2. Open `Settings`.
3. Enter the review backend URL.
4. Enter the review API token.
5. Leave `Session ID` as the default unless the review backend says otherwise.
6. Tap `Check backend`.
7. Return to the main thread and send a prompt.

## Suggested Review Prompt

`create a hello world python script and run it`

## Expected Behavior

- The app sends the request to the paired backend.
- Live progress and run status appear in the conversation.
- The final summary returns in the same thread.

## Notes for App Review

- Microphone access is optional and only needed for voice input.
- Local-network access is used when the backend is on the same network.
- For non-local connections, the production app expects a secure backend URL such as HTTPS.
