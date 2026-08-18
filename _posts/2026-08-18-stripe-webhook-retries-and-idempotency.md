---
title: "Stripe retries a failed webhook for three days, and I found out by getting the same email three times"
date: 2026-08-18
excerpt: "A webhook that failed once during setup kept being retried in the background. Once the underlying bug was fixed, every one of those retries succeeded — and every one of them sent a real customer the same email again."
---

**TL;DR**: Stripe webhook delivery is at-least-once, not exactly-once. If a webhook fails for any reason and you fix the cause later, every queued retry succeeds afterward — and if your handler isn't idempotent, that means re-running your whole side effect (sending an email, granting access, provisioning something) once per retry. Keep a marker per event/session and check it before acting, not just on send.

## The setup

A small toolkit sold as a one-time purchase: buy via a Stripe Payment Link, a webhook fires on `checkout.session.completed`, a Cloudflare Worker verifies the signature and emails a download link. Straightforward, and it had already been tested end-to-end with a real charge before going live.

Shortly after that real charge, three separate copies of the exact same download email arrived, roughly thirty minutes apart.

## What actually happened

Nothing was resending on my end. Nothing in the Worker was looping. The explanation was upstream: the very first delivery attempt for that charge had failed — a webhook secret had been misconfigured minutes earlier — so Stripe's signature check on my side rejected it with a 400.

Stripe's webhook delivery isn't "try once and give up." A non-2xx response is treated as a delivery failure, and Stripe retries on a backoff schedule for up to three days. The first few retries land roughly every few minutes to half an hour depending on how long the endpoint's been failing.

The secret got fixed a few minutes after the first failure. From Stripe's side, nothing about that mattered — it just kept retrying the same event on its normal schedule. Once the secret was correct, the *next* retry succeeded. So did the one after that. Each one was a completely valid, correctly signed, legitimate-looking webhook for a real completed checkout — because it was. Nothing distinguished retry three from delivery one except that my endpoint had already acted on delivery one's twin.

## Why this is easy to miss until it costs you

The natural mental model when building a webhook handler is "an event happens once, so my handler runs once." That model is wrong in a way that doesn't show up in testing, because a clean test run typically *doesn't* have a failed first attempt — you write the handler, it works, you ship it. The retry behavior only becomes visible the first time something fails at exactly the wrong moment: mid-deploy, during a secret rotation, during any transient error on either side.

And the failure mode isn't a crash or an error someone will report. It's a customer quietly getting the same email two or three times, mildly annoyed, possibly assuming something is wrong with the business rather than realizing the delivery layer is precisely doing what it's specified to do.

## The fix

Stripe's Checkout Session ID is a stable identifier for the same real-world event across every retry. That's the natural idempotency key: before acting, check whether that session has already been handled; if it has, acknowledge and stop.

```js
const marker = `delivered/${session.id}`;
if (await env.TOOLKIT_BUCKET.head(marker)) {
  console.log(`Session ${session.id} already delivered; skipping duplicate send.`);
  return new Response('ok (already delivered)', { status: 200 });
}

try {
  const downloadUrl = await createDownloadUrl(url.origin, env.DOWNLOAD_SIGNING_SECRET);
  await sendDownloadEmail(env, email, downloadUrl);
  // Written only after a confirmed send, so a failed attempt stays retryable.
  await env.TOOLKIT_BUCKET.put(
    marker,
    JSON.stringify({ email, deliveredAt: new Date().toISOString(), eventId: event.id }),
  );
  return new Response('ok', { status: 200 });
} catch (err) {
  // 500 so Stripe retries — a transient send failure shouldn't lose a sale.
  return new Response('delivery failed', { status: 500 });
}
```

The ordering matters as much as the check. The marker is written *after* the email send succeeds, not before it and not unconditionally. Writing it earlier would mean a transient failure in the email provider permanently marks the session as handled, and the customer never gets their download at all — trading a duplicate-email bug for a much worse silent-failure bug. The retry mechanism that caused this problem is also the thing you want protecting you against provider outages; the fix has to keep both properties.

## How to check it without waiting for another real charge

You don't need to make another purchase to verify this. Forge a correctly signed request against your own secret and send it directly:

```bash
SESSION="cs_idempotency_test_$(date +%s)"
# ...compute t=<timestamp>,v1=<hmac-sha256 of "<timestamp>.<body>" with the webhook secret>...

curl -X POST "$WEBHOOK_URL" -H "stripe-signature: $SIG" --data "$BODY"   # expect: ok
curl -X POST "$WEBHOOK_URL" -H "stripe-signature: $SIG" --data "$BODY"   # expect: ok (already delivered)
curl -X POST "$WEBHOOK_URL" -H "stripe-signature: $SIG" --data "$BODY"   # expect: ok (already delivered)
```

Same technique as forging a signature to test rejection — construct the real thing yourself instead of guessing at what production will do.

## The generalisable habit

"At-least-once" is the standard delivery guarantee for webhooks, queues, and most event systems, precisely because "exactly-once" is expensive or impossible to guarantee end-to-end. Any time you're consuming events from a system that documents at-least-once delivery, the assumption to design against isn't "this fires once" — it's "this will eventually fire more than once, probably at the worst possible time, and my handler needs to be safe either way."

The cost of skipping that isn't a crash you'll notice in a log. It's a side effect running twice, silently, on exactly the request path most likely to be running for a real customer at the exact moment you were still shaking out the rest of the system.
