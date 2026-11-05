# Installing Interview Copilot

Takes about 2 minutes. Requires **macOS 14 (Sonoma) or newer** — works on both
Apple Silicon and Intel Macs.

## 1. Download

Download **[InterviewCopilot-macOS.zip](../../releases/latest/download/InterviewCopilot-macOS.zip)**
from the latest release and unzip it.

## 2. Move it to Applications

Drag **finder.app** (the app installs under the name **finder**) into your **Applications** folder.

## 3. Allow it to open (one time)

The app isn't from the App Store, so macOS quarantines it. Open **Terminal**
and run:

```bash
xattr -dr com.apple.quarantine /Applications/finder.app
```

*(Or: try to open it, then go to **System Settings → Privacy & Security** and
click **Open Anyway**.)*

## 4. Open it

Launch it from Spotlight (⌘Space → "finder"). There's **no window
and no Dock icon** — look for the **waveform icon in the menu bar** (top-right).

## 5. Add your API keys

Menu bar icon → **Open settings…**

- Pick an AI provider (**OpenAI**, **Anthropic**, **DeepSeek**, **Gemini**,
  **Grok**, or local **Ollama** — no key needed) and paste your key. You can switch later from the overlay's **AI** menu.
- For Screen/Scroll captures you need a vision model: OpenAI, Anthropic,
  Gemini, Grok, or an Ollama vision model (DeepSeek can't read images).
- *(Recommended)* Under **Transcription**, choose **Deepgram** and paste a
  Deepgram key for accurate speech-to-text.

## 6. Grant permissions

Click **Start listening**. macOS asks for permissions — allow them in
**System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| **Screen Recording** | To capture the call audio and for Screen/Scroll captures |
| **Microphone** | To transcribe your side |
| **Speech Recognition** | Only if you use the Apple (on-device) engine |

After granting **Screen Recording**, use menu bar → **Relaunch app**.

That's it — see the [README](README.md) for features and keyboard shortcuts.
