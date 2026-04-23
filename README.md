# IR Specific Page Scrubber

This is a small Windows PowerShell monitor for investor-relations pages.

The current example is configured around `Grace Therapeutics` and `GTx-104`, but the pattern is reusable for other IR pages where you want to watch for a narrow class of announcements and send a Telegram alert when they appear.

## What It Does

- polls a specific investor-relations press release page
- opens the most recent press release links
- extracts the press release date from each release page
- filters to releases published on the target date
- checks the release text for specific signal phrases
- sends a Telegram message when a qualifying release is found
- stores local alert state so the same release is not sent twice

In this example, the signal phrases are tuned for:

- FDA approval
- Complete Response Letter (`CRL`)

## What Is Included

- [run-tracker.ps1](./run-tracker.ps1): main watcher and notifier
- [register-task.ps1](./register-task.ps1): optional Windows Task Scheduler helper
- [tracker-config.example.json](./tracker-config.example.json): safe example config with placeholders
- `.state\tracker-state.json`: local sent-alert state after first run
- `.state\tracker.log`: local run log

No live Telegram credentials are included in the shareable version.

## Setup

1. Copy [tracker-config.example.json](./tracker-config.example.json) to `tracker-config.json`.
2. Put your Telegram bot token into `telegram.botToken`.
3. Put your Telegram private chat ID or group chat ID into `telegram.chatId`.
4. Optional: set `telegram.mentionText` if you want extra text at the top of each alert.

## Run Once

```powershell
powershell -ExecutionPolicy Bypass -File .\run-tracker.ps1 -ConfigPath .\tracker-config.json
```

## Run In Watch Mode

This keeps the script running and polls repeatedly.

```powershell
powershell -ExecutionPolicy Bypass -File .\run-tracker.ps1 -ConfigPath .\tracker-config.json -Watch -IntervalSeconds 30
```

Use a lower interval only if you are comfortable with the extra polling load on the target site.

## Test Telegram

```powershell
powershell -ExecutionPolicy Bypass -File .\run-tracker.ps1 -ConfigPath .\tracker-config.json -TestTelegram
```

## Dry Run

This shows the outgoing Telegram payload without sending it:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-tracker.ps1 -ConfigPath .\tracker-config.json -DryRun
```

## Historical Date Test

This is useful for verifying that the date parser and page matching logic are working:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-tracker.ps1 -ConfigPath .\tracker-config.json -CheckDate 2026-04-14 -DateRecognitionOnly -DryRun
```

## Telegram Setup

1. Open `@BotFather` in Telegram.
2. Run `/newbot` and create a bot.
3. Copy the bot token into `tracker-config.json`.
4. Send a message to the bot, or add it to a group and send a message there.
5. Open:

```text
https://api.telegram.org/botYOUR_BOT_TOKEN/getUpdates
```

6. Find the relevant `chat.id` in the response and copy it into `tracker-config.json`.

Notes:

- private chat IDs are typically positive numbers
- group chat IDs are often negative
- the bot must be allowed to post in the destination chat

## Customizing It

If you want to adapt this for another IR page, the main areas to change are:

- the target press release listing URL in [run-tracker.ps1](./run-tracker.ps1)
- the link-matching rules used to identify release detail pages
- the date parsing rules if the site formats dates differently
- the text patterns used to decide whether a release is alert-worthy
