# iPhone Shortcut MVP (No App Code)

This gives you immediate voice-to-backend testing from iPhone using the Shortcuts app.

## Prerequisites

- Backend installed and running (recommended via `bash ./scripts/service_macos.sh install`)
- Pairing data available in `backend/pairing.json`
- iPhone can reach `server_url` from that pairing file (localhost will not work from phone)
- Optional QR generation:
  - `bash ./scripts/pairing_qr.sh`
  - outputs `backend/pairing-qr.png` when `qrencode` is installed

## Optional one-time QR onboarding in Shortcuts

Before building the main shortcut, create a tiny helper shortcut:

1. `Scan QR/Barcode`
2. `Get Dictionary from Input`
3. `Get Dictionary Value` key `server_url` -> save to variable `ServerURL`
4. `Get Dictionary Value` key `api_token` -> save to variable `ApiToken`
5. `Show Result` (optional) to verify values

Then copy `ServerURL` and `ApiToken` into your main shortcut.

## Build Shortcut: "Voice Agent MVP"

Create a new Shortcut with these actions:

1. `Dictate Text`
- Language: your preferred language.
- Output variable: `DictatedText`.

2. `Get Contents of URL` (POST `.../v1/utterances`)
- URL: `<server_url>/v1/utterances`
- Method: `POST`
- Headers:
  - `Authorization: Bearer <api_token>`
  - `Content-Type: application/json`
- Request Body (JSON):
```json
{
  "session_id": "iphone-shortcut",
  "utterance_text": "<DictatedText>",
  "executor": "codex"
}
```
- Output variable: `CreateResponse`

3. `Get Dictionary Value`
- From: `CreateResponse`
- Key: `run_id`
- Output variable: `RunID`

4. `Repeat` (e.g. 40 times)
- Action `Wait` 0.5 seconds
- Action `Get Contents of URL` (GET `<server_url>/v1/runs/<RunID>`)
  - Header:
    - `Authorization: Bearer <api_token>`
- Action `Get Dictionary Value`
  - Key: `status`
  - Output variable: `RunStatus`
- Action `If`
  - If `RunStatus` is not `running`, then `Stop This Repeat`

5. `Get Dictionary Value`
- From latest run payload
- Key: `summary`
- Output variable: `RunSummary`

6. `Speak Text`
- Text: `RunSummary`

7. Optional: `Show Result`
- Text: full run payload for debugging.

## Notes

- For safer first test, set `"executor": "local"` before switching to `"codex"`.
- If backend is private-network only (for example Tailscale), iPhone must be on that same network.
- If Codex run fails, the run payload includes detailed failure events.
