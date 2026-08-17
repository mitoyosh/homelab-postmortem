---
title: "Your Discord bot is ignoring you, and the status output is lying about why"
date: 2026-08-17
excerpt: "A self-hosted agent bot connected fine, posted fine, and silently discarded every message aimed at it. The status line blamed a Discord intent. The actual cause was an unset applicationId — and the logs said so all along."
---

**TL;DR**: If a self-hosted bot connects successfully, can post to a channel, but never responds when you `@mention` it, check whether your framework has the bot's own **application ID** configured. Without it, the bot receives your message, fails to recognise its own mention, and drops it. Any "message content intent" warning you see at the same time is probably a red herring.

## The symptom

The bot was up. `channels status --probe` said `connected`, `works`. Sending *from* the bot into a Discord channel worked on the first try — the test message landed instantly.

Then I mentioned the bot in that same channel and got nothing. No error, no reply, no visible reaction. Just silence.

## The misleading clue

The status line included this:

```
intents:content=limited
```

That looks like an answer. "Content is limited" reads exactly like the well-known Discord gotcha where a bot can't read message text because **Message Content Intent** isn't enabled in the Discord Developer Portal. That intent genuinely is required for bots to see the text of ordinary guild messages, it genuinely is off by default, and forgetting it genuinely is one of the most common Discord bot mistakes.

So I chased it. Enabled the intent in the portal — it was already on. Restarted the gateway to force a fresh connection — still `content=limited`. Went looking for a config key to force it on, found documentation describing `intents.messageContent`, tried to set it, and got:

```
Config validation failed: channels.discord.intents:
must not have additional properties: "messageContent"
```

That error is the moment the investigation should have turned, and it's worth dwelling on. The documented key didn't exist in the schema. Two readings were available: either the docs were for a different version, or I was in the wrong place entirely. I checked the actual schema:

```bash
openclaw config schema | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps(d['properties']['channels']['properties']['discord']['properties']['intents'], indent=2))
"
```

The whole set of supported keys came back as `presence`, `guildMembers`, `voiceStates`. There was **no message-content key at all** — not disabled, not misspelled, not present. Which meant `content=limited` could not be something I was failing to configure.

## What the logs actually said

Reading the raw channel log instead of the status summary took about ten seconds and settled it:

```
info {"module":"discord-auto-reply"}
{"channelId":"...","reason":"no-mention"}
discord: skipping guild message
```

Two things are true in that one line, and they point in opposite directions from where I'd been looking:

1. **The bot received the message.** It could not log a decision about a message it never got. Message content was never the problem.
2. **It decided the message contained no mention** — and dropped it on that basis.

And critically, the log line was *identical* for a plain message and for a message where I had explicitly `@mentioned` the bot. Same `reason: "no-mention"`, both times. The bot wasn't failing to read my message. It was failing to recognise itself in it.

## The cause

A Discord mention arrives in the message payload as `<@BOT_USER_ID>`. To decide "was I mentioned?", the receiving code has to compare that ID against its own. If the framework doesn't know its own application/client ID, that comparison can't succeed, and every mention looks like a non-mention.

The config had no `applicationId` set:

```bash
$ openclaw config get channels.discord.applicationId
Config path not found: channels.discord.applicationId
```

The bot's own ID had been sitting in the startup log the whole time:

```
discord client initialized as 1538471699438370957; awaiting gateway readiness
```

Setting it fixed the bot immediately:

```bash
openclaw config set --json channels.discord.applicationId '"1538471699438370957"'
```

Note the `--json` flag and the nested quotes. Without them the value is parsed as a number and rejected — Discord snowflake IDs are numeric strings, and they must stay strings.

Restart the gateway, mention the bot, get a reply.

## Why this is worth writing down

Not because the fix is hard — it's one config key. It's worth writing down because of how the failure presents itself.

Everything visible pointed at the intent. The status output named it. The symptom (bot can't act on my messages) matches the intent problem exactly. The intent problem is far more commonly discussed online, so every search reinforces it. And the fix for the intent problem — toggling a switch in the Developer Portal — is easy enough that you'll happily do it, see nothing change, and conclude you need to dig *deeper into intents* rather than sideways into something else.

Meanwhile the actual cause is invisible from the status output. A missing `applicationId` doesn't warn you. It doesn't degrade a status line. It just quietly makes one boolean always false.

## The generalisable habit

When a status summary and a raw log disagree about what's happening, **the log is describing events and the summary is describing an interpretation**. The summary is a convenience layer written by someone who guessed which distinctions would matter to you; it flattens away detail by design. The log records what the code actually decided, and it tells you *why* in the code's own terms.

`reason: "no-mention"` was a precise, correct, complete description of the failure. It was available before I made my first change. I reached for the status line because it was already on screen, and spent the next several steps debugging an interpretation instead of an event.

So: when a component "connects fine but doesn't react", check the receive path's decision log before you touch a single config value. And when a documented config key doesn't exist in the running schema, treat that as evidence you're in the wrong subsystem — not as an invitation to find a different way to set it.
