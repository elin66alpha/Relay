---
title: Mentions and rounds
category: Swarms
order: 520
summary: Use @ to choose who answers, run members in parallel, let members summon each other, and stop.
keywords: @, mention, summon, parallel, round, wave, stop, RELAY_SWARM_MAX_HOPS
---

## Choose who answers with @

In the Swarm composer, write `@member-name` to choose who answers, for example `@claude look at this error`.

When one message mentions several members, Relay snapshots the transcript once, gives each member what is new since it last spoke, and runs them **in parallel**. Each member works through its own private session one turn at a time.

## Members summon each other

Each member's prompt lists the other members and the `@name` that reaches each. Whoever a member's reply names speaks next: the round continues with another wave, and the newly summoned members see the previous wave's replies.

To stop two members from naming each other forever (and billing all the while), the waves members start after your message are capped, at **3** by default, set by the backend's `RELAY_SWARM_MAX_HOPS`; at 0 only you can summon. A member cannot summon itself, and a failed or cancelled reply summons no one.

## One round at a time

A Swarm runs one round at a time. While it runs, the composer shows **Stop** instead of Send, even after you leave and come back or on another device. A message sent meanwhile is refused, because two rounds would interleave in the one transcript.

Swarm replies are not streamed: each member shows as working until its whole reply is in.

## Stop

**Stop** cancels the round for every member, including members on other machines.

## Not supported

Links in Swarm chats do not open, and members produce no background replies.
