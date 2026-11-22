# RimeLingo

[中文](README.md)

RimeLingo (灵译输入法) is a Chinese input method for macOS built on [RIME](https://rime.im). Besides everyday pinyin input, it translates what you type into English or Japanese as you go and inserts the translation once you confirm it. It can also translate text you have selected in an input field.

## Requirements

- macOS 15 or later
- A Mac with Apple silicon
- On-device translation needs Apple Intelligence turned on. You can use your own online translation service instead (see "Configuration").

## Installation

1. Download `RimeLingo-<version>.zip` from the [Releases](https://github.com/leaker/rime-lingo/releases/latest) page and unzip it.
2. Move `RimeLingo.app` to `~/Library/Input Methods/` (in Finder press ⇧⌘G and paste that path).
3. Open Terminal and run:

   ```bash
   ~/Library/Input\ Methods/RimeLingo.app/Contents/MacOS/RimeLingo --install
   ```

4. Log out and back in once.
5. If "灵译输入法" is not in the input menu of the menu bar yet, open System Settings › Keyboard › Input Sources › Edit…, click "+", and add it under "Chinese, Simplified".

Later versions download and install themselves while the Mac is idle. You do not repeat these steps.

## Usage

### Ordinary input

It works like other pinyin input methods: type pinyin, pick a candidate with Space or a number key. Press Shift to switch between Chinese and English.

### Translate as you type

1. In any input field press **⌃⌥⌘E** (to English) or **⌃⌥⌘J** (to Japanese).
2. Type Chinese as usual. The translation appears in a preview panel next to the cursor and follows your input.
3. Press **⌥↩** to insert the translation, or **Esc** to cancel.

Until you insert the translation you can keep editing the Chinese text: move the cursor with the arrow keys, insert or delete, and the translation updates.

### Translate selected text

Select text where you can type (a chat field, a document, an editor) and press **⌃⌥⌘E** or **⌃⌥⌘J**. When the preview panel shows the translation you can replace the original, copy the translation, or cancel.

Selections in read-only content (web page text, PDFs) are not supported.

### Password fields

In password fields RimeLingo does nothing: key presses go straight to the system, no candidate window appears and no translation starts.

## Configuration

Click the input method icon in the menu bar and choose "设置" (Settings). The settings app is in Chinese. The most used sections:

| Section | What it does |
| --- | --- |
| 快捷键 (Shortcuts) | Change the shortcuts for "translate to English", "translate to Japanese" and "insert translation" |
| AI 助手 (AI assistant) | Choose the translation service: the on-device model, or any online service with an OpenAI-compatible API (enter its address and key) |
| 输入方案 (Schemas) | Full pinyin, double pinyin and other schemas |
| 输入习惯, 中英切换, 模糊音与拼写 | Number of candidates, switching keys, fuzzy pinyin |
| 外观 (Appearance) | Colours, fonts, horizontal or vertical candidates |
| 词库, 自定义短语, 常用语 | Add dictionaries and your own phrases |
| 应用 (Applications) | Set the default Chinese or English state per application |

### Migrating from Squirrel

On the "概览" (Overview) page click "导入" (Import) to bring over your Squirrel schemas and custom configuration. Importing does not change `~/Library/Rime`.

### Where data is kept

- Configuration and dictionaries: `~/Library/RimeLingo/Rime`
- Logs: `~/Library/Logs/RimeLingo`

## Privacy

- With the on-device model, text does not leave your Mac.
- Text is sent out only if you configure an online service under "AI 助手", and only to the address you entered.
- Input statistics are off by default and stay on your Mac when turned on.

## Updates and removal

- **Updates**: RimeLingo checks for a new version once a day, verifies its signature and installs it while the Mac is idle. You can turn this off on the "概览" (Overview) page.
- **Removal**: remove 灵译输入法 in System Settings › Keyboard › Input Sources, then delete `~/Library/Input Methods/RimeLingo.app`. To remove your data as well, delete `~/Library/RimeLingo`.

## License

See [LICENSE](LICENSE).
