---
title: Mentions and rounds
category: Swarms
order: 520
summary: Use @ to choose who answers, run members in mention order, let members summon each other, and stop.
keywords: @, mention, summon, order, round, wave, stop, RELAY_SWARM_MAX_HOPS
---

## Choose who answers with @

In the Swarm composer, write `@member-name` to choose who answers, for example `@claude look at this error` or `@studio:claude check the server logs`. A member answers to its agent key, its `@handle` and its nickname, in any language and with no space needed after it: a member nicknamed 架构师 answers `@架构师看一下`.

When one message mentions several members, Relay runs them **one after another in mention order**. Each member is planned right before it runs, so it sees what is new since it last spoke — including replies already given earlier in the same wave. A failed reply does not count as speaking, so a member that failed sees the messages again on its next turn; after its session is reset (a new work directory, or a member on another machine removed and added again), it reads the whole conversation again.

## Members summon each other

Each member's prompt states its own machine and work directory, and lists the other members with their `@handle`, machine and work directory. Whoever a member's reply names speaks in the next wave — unless that member already ran after the reply in the same wave and has already seen it.

To stop two members from naming each other forever (and billing all the while), the waves members start after your message are capped, at **3** by default, set by the backend's `RELAY_SWARM_MAX_HOPS`; at 0 only you can summon. A member cannot summon itself, and a failed or cancelled reply summons no one.

## One round at a time per Swarm

Each Swarm runs one round at a time, while different Swarms can run concurrently. While a Swarm's round runs, its composer shows **Stop** instead of Send, even after you leave and come back or on another device; switching to another Swarm lets you send there immediately. A second message to the same busy Swarm is refused. If the connection drops during a long round, for example when the phone goes to the background, the round keeps running and the composer still shows **Stop**.

Swarm replies are not streamed: each member shows as working until its whole reply is in.

## Stop

**Stop** cancels the round for every member, including members on other machines.

## Not supported

Links in Swarm chats do not open, and members produce no background replies.
