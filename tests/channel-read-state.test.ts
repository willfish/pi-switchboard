import assert from "node:assert/strict";
import test from "node:test";
import {
  CACHE_MESSAGE_LIMIT, MAX_CHECKPOINTS, MAX_TRACKED_READS, SCOPE_ENTRY, applyOperatorCache, assessRead, assessTail,
  backgroundChannelNames, beginTrackedRead, commitChannelRead, compareSequence, coordinationScopeFromBranch,
  cachedAfter, emptyChannelReadState, emptyOperatorCache, invalidateChannelReads, messagesOrdered, noteDelivery, readAfter,
  releaseChannelRead, type ChannelReadState,
} from "../extension/channel-read-state.ts";
import type { ChannelMessage, ChannelPage } from "../extension/channels.ts";

const epochA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const epochB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const epochC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const sender = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

function message(seq: string, body = `body ${seq}`, postedAt = 1_700_000_000): ChannelMessage {
  return { seq, id: sender, channel: "general", from: sender, kind: "say", body, postedAt };
}

function page(overrides: Partial<ChannelPage> = {}, messages = [message("2"), message("10")]): ChannelPage {
  const first = messages[0]?.seq ?? "0";
  const last = messages.at(-1)?.seq ?? "0";
  return {
    epoch: epochA, channel: "general", window: "recent", fromSequence: first, toSequence: last,
    retainedFrom: messages.length ? first : "0", retainedTo: messages.length ? last : "0",
    coverage: messages.length ? "complete" : "empty", caughtUp: true, earlier: false, nextCursor: null, earlierCursor: null,
    messages, ...overrides,
  };
}

function delivered(state: ChannelReadState, channel: string, deliveredPage: ChannelPage, mode: "recent" | "new" = "recent") {
  const begun = beginTrackedRead(state, channel, mode);
  assert.equal(begun.ok, true);
  if (!begun.ok) throw new Error("busy");
  return { ticket: begun.ticket, state: noteDelivery(begun.state, begun.ticket, deliveredPage) };
}

test("scope restore uses the latest custom entry and explicit null overrides an older channel", () => {
  assert.equal(coordinationScopeFromBranch([]), null);
  assert.equal(coordinationScopeFromBranch([{ type: "custom", customType: SCOPE_ENTRY, data: { channel: "reviews" } }]), "reviews");
  assert.equal(coordinationScopeFromBranch([
    { type: "custom", customType: SCOPE_ENTRY, data: { channel: "reviews" } },
    { type: "custom", customType: SCOPE_ENTRY, data: { channel: null } },
  ]), null);
  assert.equal(coordinationScopeFromBranch([{ type: "custom", customType: SCOPE_ENTRY, data: { channel: "Bad_Name" } }]), null);
  assert.equal(coordinationScopeFromBranch([{ type: "message" }, { type: "custom", customType: "other", data: { channel: "reviews" } }]), null);
});

test("background names follow explicit scope, otherwise the cwd default, and always include general", () => {
  assert.deepEqual(backgroundChannelNames("work", null), ["general", "work"]);
  assert.deepEqual(backgroundChannelNames("general", null), ["general"]);
  assert.deepEqual(backgroundChannelNames("work", "reviews"), ["general", "reviews"]);
  assert.deepEqual(backgroundChannelNames("work", "general"), ["general"]);
});

test("new reads start at the recent tail and then use the returned checkpoint without requiring contiguous sequences", () => {
  let state = emptyChannelReadState();
  assert.equal(readAfter(state, "general", "new", true), "0");
  assert.equal(readAfter(state, "general", "recent", true), "0");
  const first = delivered(state, "general", page({}, [message("2"), message("10")]));
  const committed = commitChannelRead(first.state, first.ticket, epochA, "2");
  assert.equal(committed.accepted, true);
  state = committed.state;
  assert.equal(readAfter(state, "general", "new", true), "2");
  const second = delivered(state, "general", page({ fromSequence: "10", toSequence: "10" }, [message("10")]));
  const skipped = commitChannelRead(second.state, second.ticket, epochA, "10");
  assert.equal(skipped.accepted, true);
  assert.equal(skipped.state.checkpoints.get("general")?.after, "10");
  assert.equal(compareSequence("2", "10") < 0, true);
  assert.equal(compareSequence("9", "10") < 0, true);
  assert.equal(Number.isNaN(compareSequence("01", "1")), true);
});

test("empty or backward commits retain the previous checkpoint and release the matching ticket", () => {
  const first = delivered(emptyChannelReadState(), "general", page({}, [message("4"), message("10")]));
  const advanced = commitChannelRead(first.state, first.ticket, epochA, "10");
  const empty = delivered(advanced.state, "general", page({ coverage: "empty", fromSequence: "0", toSequence: "0", retainedFrom: "4", retainedTo: "10" }, []));
  assert.equal(commitChannelRead(empty.state, empty.ticket, epochA, "0").accepted, false);
  assert.equal(empty.state.checkpoints.get("general")?.after, "10");
  const retained = releaseChannelRead(empty.state, empty.ticket);
  assert.equal(retained.checkpoints.get("general")?.after, "10");
  assert.equal(retained.busy.has("general"), false);
  const again = delivered(retained, "general", page({}, [message("4"), message("10")]), "new");
  const backward = commitChannelRead(again.state, again.ticket, epochA, "4");
  assert.equal(backward.accepted, false);
  assert.equal(backward.state.checkpoints.get("general")?.after, "10");
  assert.equal(backward.state.busy.has("general"), false);
  const same = delivered(backward.state, "general", page({}, [message("10")]));
  const unchanged = commitChannelRead(same.state, same.ticket, epochA, "10");
  assert.equal(unchanged.accepted, true);
  assert.equal(unchanged.state.checkpoints.get("general")?.after, "10");
});

test("stale tickets, malformed pages, and epoch churn do not advance", () => {
  const begun = beginTrackedRead(emptyChannelReadState(), "general");
  assert.equal(begun.ok, true);
  if (!begun.ok) return;
  const invalidated = invalidateChannelReads(begun.state);
  assert.equal(commitChannelRead(invalidated, begun.ticket, epochA, "2").accepted, false);
  assert.equal(invalidated.checkpoints.size, 0);
  assert.equal(assessRead(invalidated, begun.ticket, "new", page(), "primary").kind, "fail");
  const current = delivered(emptyChannelReadState(), "general", page());
  assert.equal(assessRead(current.state, current.ticket, "new", page({}, [message("5"), message("3")]), "primary").kind, "fail");
  assert.equal(messagesOrdered([message("2"), message("10")]), true);
  const checkpointed = commitChannelRead(current.state, current.ticket, epochA, "10");
  const next = beginTrackedRead(checkpointed.state, "general");
  assert.equal(next.ok, true);
  if (!next.ok) return;
  const delta = page({ epoch: epochB }, [message("12")]);
  assert.deepEqual(assessRead(next.state, next.ticket, "new", delta, "primary"), { kind: "refetch" });
  const churn = assessTail(next.state, next.ticket, page({ epoch: epochC }, [message("12")]), epochB);
  assert.deepEqual(churn, { kind: "fail", reason: "channel epoch changed" });
  assert.equal(commitChannelRead(next.state, next.ticket, epochC, "12").accepted, false);
  assert.equal(next.state.checkpoints.get("general")?.epoch, epochA);
});

test("a matching fresh tail is a reset and may replace the checkpoint epoch", () => {
  const current = delivered(emptyChannelReadState(), "general", page({}, [message("2")]));
  const checkpointed = commitChannelRead(current.state, current.ticket, epochA, "2");
  const next = beginTrackedRead(checkpointed.state, "general");
  assert.equal(next.ok, true);
  if (!next.ok) return;
  const tail = page({ epoch: epochB, fromSequence: "9", toSequence: "15" }, [message("9"), message("15")]);
  assert.deepEqual(assessTail(next.state, next.ticket, tail, epochB), { kind: "deliver", reset: true });
  const noted = noteDelivery(next.state, next.ticket, tail);
  const committed = commitChannelRead(noted, next.ticket, epochB, "9");
  assert.equal(committed.accepted, true);
  assert.deepEqual(committed.state.checkpoints.get("general"), { epoch: epochB, after: "9" });
  assert.equal(commitChannelRead(noted, next.ticket, epochA, "2").accepted, false);
});

test("recent truncation can rewind the returned boundary and new mode cannot", () => {
  const window = page({}, [message("2"), message("10"), message("20")]);
  const opened = delivered(emptyChannelReadState(), "general", window, "recent");
  const truncated = commitChannelRead(opened.state, opened.ticket, epochA, "2");
  assert.equal(truncated.accepted, true);
  assert.equal(readAfter(truncated.state, "general", "new", true), "2");
  const drained = delivered(truncated.state, "general", page({ fromSequence: "10", toSequence: "20" }, [message("10"), message("20")]), "new");
  const caught = commitChannelRead(drained.state, drained.ticket, epochA, "20");
  assert.equal(caught.state.checkpoints.get("general")?.after, "20");
  const reopened = delivered(caught.state, "general", window, "recent");
  const rewind = commitChannelRead(reopened.state, reopened.ticket, epochA, "10");
  assert.equal(rewind.accepted, true);
  assert.equal(rewind.state.checkpoints.get("general")?.after, "10");
  assert.equal(readAfter(rewind.state, "general", "new", true), "10");
  const held = delivered(caught.state, "general", window, "new");
  const blocked = commitChannelRead(held.state, held.ticket, epochA, "10");
  assert.equal(blocked.accepted, false);
  assert.equal(blocked.state.checkpoints.get("general")?.after, "20");
});

test("empty completion keeps a same-epoch boundary and records a new epoch without a message sequence", () => {
  const opened = delivered(emptyChannelReadState(4), "general", page({}, [message("2")]));
  const saved = commitChannelRead(opened.state, opened.ticket, epochA, "2");
  const same = delivered(saved.state, "general", page({ coverage: "empty", fromSequence: "0", toSequence: "0", retainedFrom: "2", retainedTo: "2" }, []));
  const retained = commitChannelRead(same.state, same.ticket, epochA, null);
  assert.equal(retained.accepted, true);
  assert.deepEqual(retained.state.checkpoints.get("general"), { epoch: epochA, after: "2" });
  const reset = delivered(retained.state, "general", page({ epoch: epochB, coverage: "empty", fromSequence: "0", toSequence: "0", retainedFrom: "0", retainedTo: "0" }, []));
  const sentinel = commitChannelRead(reset.state, reset.ticket, epochB, null);
  assert.equal(sentinel.accepted, true);
  assert.deepEqual(sentinel.state.checkpoints.get("general"), { epoch: epochB, after: "0" });
  assert.equal(readAfter(sentinel.state, "general", "new", true), "0");
  assert.equal(assessRead(sentinel.state, undefined, "new", page({ epoch: epochC }, [message("9")]), "primary").kind, "deliver");
  const nonempty = delivered(sentinel.state, "general", page({ epoch: epochB }, [message("9")]));
  const hidden = commitChannelRead(nonempty.state, nonempty.ticket, epochB, null);
  assert.equal(hidden.accepted, false);
  assert.deepEqual(hidden.state.checkpoints.get("general"), { epoch: epochB, after: "0" });
  assert.equal(hidden.state.busy.has("general"), false);
});

test("request tokens are one bounded counter and a replaced context cannot release the new read", () => {
  const first = beginTrackedRead(emptyChannelReadState(1), "general");
  assert.equal(first.ok, true);
  if (!first.ok) return;
  const second = beginTrackedRead(first.state, "reviews");
  assert.equal(second.ok, true);
  if (!second.ok) return;
  assert.deepEqual([first.ticket.request, second.ticket.request], [1, 2]);
  const replaced = beginTrackedRead(emptyChannelReadState(9), "general");
  assert.equal(replaced.ok, true);
  if (!replaced.ok) return;
  assert.equal(releaseChannelRead(replaced.state, first.ticket), replaced.state);
  assert.equal(commitChannelRead(replaced.state, first.ticket, epochA, "2").accepted, false);
  assert.equal(replaced.state.busy.has("general"), true);
  let limited = emptyChannelReadState(3);
  for (let index = 0; index < MAX_TRACKED_READS; index += 1) {
    const opened = beginTrackedRead(limited, `c${index}`);
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    limited = opened.state;
  }
  assert.deepEqual(beginTrackedRead(limited, "overflow"), { ok: false, reason: "channel read limit" });
  const exhausted = beginTrackedRead({ ...emptyChannelReadState(3), nextRequest: Number.MAX_SAFE_INTEGER }, "general");
  assert.deepEqual(exhausted, { ok: false, reason: "channel read limit" });
});

test("concurrent tracked reads of one channel are rejected and another channel is independent", () => {
  const first = beginTrackedRead(emptyChannelReadState(), "general");
  assert.equal(first.ok, true);
  if (!first.ok) return;
  assert.deepEqual(beginTrackedRead(first.state, "general"), { ok: false, reason: "channel read in progress" });
  const other = beginTrackedRead(first.state, "reviews");
  assert.equal(other.ok, true);
  const released = releaseChannelRead(first.state, first.ticket);
  assert.equal(beginTrackedRead(released, "general").ok, true);
  assert.equal(releaseChannelRead(released, first.ticket), released);
});

test("checkpoints stay capped and invalidation drops them without reusing an in-flight token", () => {
  let state = emptyChannelReadState();
  for (let index = 0; index < MAX_CHECKPOINTS + 1; index += 1) {
    const name = `c${index}`;
    const opened = delivered(state, name, page({ channel: name, epoch: epochA }, [{ ...message("2"), channel: name }]));
    state = commitChannelRead(opened.state, opened.ticket, epochA, "2").state;
  }
  assert.equal(state.checkpoints.size, MAX_CHECKPOINTS);
  assert.equal(state.checkpoints.has("c0"), false);
  assert.equal(state.checkpoints.has(`c${MAX_CHECKPOINTS}`), true);
  const token = beginTrackedRead(state, "general");
  assert.equal(token.ok, true);
  if (!token.ok) return;
  const cleared = invalidateChannelReads(token.state);
  assert.equal(cleared.context, token.state.context + 1);
  assert.equal(cleared.checkpoints.size, 0);
  assert.equal(cleared.busy.size, 0);
  assert.equal(commitChannelRead(cleared, token.ticket, epochA, "2").accepted, false);
});

test("operator cache does not inherit constructor for a legal channel name", () => {
  const empty = emptyOperatorCache();
  assert.equal(cachedAfter(empty, "constructor"), "0");
  assert.equal(Object.hasOwn(empty.pages, "constructor"), false);
  const stored = applyOperatorCache(empty, "constructor", page({ channel: "constructor" }, [{ ...message("4", "kept"), channel: "constructor" }]), 1_700_000_000);
  assert.equal(stored.applied, true);
  assert.equal(stored.cache.pages.constructor.messages[0]?.body, "kept");
  assert.equal(cachedAfter(stored.cache, "constructor"), "4");
  const again = applyOperatorCache(stored.cache, "constructor", page({ channel: "constructor", fromSequence: "6", toSequence: "6", retainedFrom: "4", retainedTo: "6" }, [{ ...message("6", "next"), channel: "constructor" }]), 1_700_000_000);
  assert.deepEqual(again.cache.pages.constructor.messages.map(item => item.seq), ["4", "6"]);
});

test("operator cache prunes retention, replaces gap and epoch, and keeps empty forward history", () => {
  const now = 1_700_000_000;
  const initial = applyOperatorCache(emptyOperatorCache(), "general", page({ retainedFrom: "1", retainedTo: "10" }, [message("1", "old", now - 90_000), message("2", "kept", now)]), now);
  assert.equal(initial.applied, true);
  assert.deepEqual(initial.cache.pages.general.messages.map(item => item.seq), ["1", "2"]);
  const expired = applyOperatorCache(initial.cache, "general", page({ messages: [], coverage: "empty", fromSequence: "0", toSequence: "0", retainedFrom: "1", retainedTo: "2", caughtUp: true }, []), now);
  assert.equal(expired.cache.pages.general.messages.some(item => item.body === "old"), false);
  assert.equal(expired.cache.pages.general.messages.some(item => item.body === "kept"), true);
  assert.notEqual(expired.cache.pages.general.coverage, "empty");
  const gap = applyOperatorCache(expired.cache, "general", page({ coverage: "gap", fromSequence: "20", toSequence: "20", retainedFrom: "20", retainedTo: "20" }, [message("20", "tail", now)]), now);
  assert.deepEqual(gap.cache.pages.general.messages.map(item => item.body), ["tail"]);
  assert.equal(gap.cache.pages.general.coverage, "gap");
  const emptyForward = applyOperatorCache(gap.cache, "general", page({ messages: [], coverage: "empty", fromSequence: "0", toSequence: "0", retainedFrom: "20", retainedTo: "20" }, []), now);
  assert.equal(emptyForward.cache.pages.general.messages[0]?.body, "tail");
  assert.equal(emptyForward.cache.pages.general.coverage, "gap");
  const emptyJournal = applyOperatorCache(emptyForward.cache, "general", page({ messages: [], coverage: "empty", fromSequence: "0", toSequence: "0", retainedFrom: "0", retainedTo: "0" }, []), now);
  assert.equal(emptyJournal.cache.pages.general.coverage, "empty");
  assert.equal(emptyJournal.cache.pages.general.messages.length, 0);
  assert.equal(emptyJournal.cache.after.general, undefined);
  const other = applyOperatorCache(initial.cache, "reviews", page({ channel: "reviews" }, [{ ...message("3", "review", now), channel: "reviews" }]), now);
  const reset = applyOperatorCache(other.cache, "general", page({ epoch: epochB }, [message("4", "reset", now)]), now);
  assert.equal(reset.cache.pages.reviews, undefined);
  assert.equal(reset.cache.epoch, epochB);
  const unordered = applyOperatorCache(reset.cache, "general", page({}, [message("8"), message("7")]), now);
  assert.equal(unordered.applied, false);
  assert.equal(unordered.cache.pages.general.messages[0]?.body, "reset");
  const bulky = applyOperatorCache(emptyOperatorCache(), "general", page({}, [message("1", "aaaa", now), message("2", "bbbb", now), message("4", "cccc", now)]), now, { messages: CACHE_MESSAGE_LIMIT, bytes: 4 });
  assert.deepEqual(bulky.cache.pages.general.messages.map(item => item.seq), ["4"]);
  assert.equal(bulky.cache.pages.general.earlier, true);
  assert.equal(bulky.cache.pages.general.fromSequence, "4");
});
