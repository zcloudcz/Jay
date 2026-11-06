// ---------------------------------------------------------------------------
// PendingCallStoreTests.cs - Lifetime rules of ringing calls (pure, fake clock)
// ---------------------------------------------------------------------------
// The store holds offers for offline callees whose phone is ringing (spec
// 2026-11-06-call-ringing 1.2). Its rules are checked here without a hub or
// database: 45 s ring timeout -> tombstone, 2 min tombstone life, caps, and
// "delivered once". CallRingingTests covers the same store through SignalR.
// ---------------------------------------------------------------------------

using FluentAssertions;
using CallType.Api.Services;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Services;

public class PendingCallStoreTests
{
    private readonly FakeTimeProvider _clock = new(new DateTimeOffset(2026, 11, 6, 12, 0, 0, TimeSpan.Zero));
    private readonly Guid _caller = Guid.NewGuid();
    private readonly Guid _target = Guid.NewGuid();

    private PendingCallStore NewStore() => new(_clock);

    private PendingCall Call(string callId, Guid? caller = null) => new()
    {
        CallId = callId,
        CallerDeviceId = caller ?? _caller,
        TargetDeviceId = _target,
        Signals = { new PendingCallSignal("offer", callId) },
    };

    [Fact]
    public void Signals_are_kept_in_order_and_taken_exactly_once()
    {
        var store = NewStore();
        store.TryAdd(Call("c1")).Should().BeTrue();
        store.TryAppend(_target, "c1", _caller, new("ice-candidate", "a")).Should().BeTrue();
        store.TryAppend(_target, "c1", _caller, new("ice-candidate", "b")).Should().BeTrue();

        var first = store.TakeAll(_target);
        var second = store.TakeAll(_target);

        first.Calls.Single().Signals.Select(s => s.Payload).Should().Equal("c1", "a", "b");
        second.Calls.Should().BeEmpty();
        second.Tombstones.Should().BeEmpty();
    }

    [Fact]
    public void Another_callers_ice_or_an_unknown_call_is_not_appended()
    {
        var store = NewStore();
        store.TryAdd(Call("c1"));

        store.TryAppend(_target, "c1", Guid.NewGuid(), new("ice-candidate", "x")).Should().BeFalse();
        store.TryAppend(_target, "other", _caller, new("ice-candidate", "x")).Should().BeFalse();
        store.TakeAll(_target).Calls.Single().Signals.Should().HaveCount(1);
    }

    [Fact]
    public void Signals_beyond_the_cap_are_dropped_but_still_handled()
    {
        var store = NewStore();
        store.TryAdd(Call("c1"));
        for (var i = 0; i < PendingCallStore.MaxSignalsPerCall + 10; i++)
            store.TryAppend(_target, "c1", _caller, new("ice-candidate", i.ToString())).Should().BeTrue();

        store.TakeAll(_target).Calls.Single().Signals.Should().HaveCount(PendingCallStore.MaxSignalsPerCall);
    }

    [Fact]
    public void Duplicate_call_id_and_the_per_target_cap_are_refused()
    {
        var store = NewStore();
        store.TryAdd(Call("c0")).Should().BeTrue();
        store.TryAdd(Call("c0")).Should().BeFalse();
        for (var i = 1; i < PendingCallStore.MaxPendingPerTarget; i++)
            store.TryAdd(Call("c" + i, Guid.NewGuid())).Should().BeTrue();

        store.TryAdd(Call("one-too-many", Guid.NewGuid())).Should().BeFalse();
    }

    [Fact]
    public void Ring_timeout_turns_the_call_into_a_tombstone_that_lives_two_minutes()
    {
        var store = NewStore();
        store.TryAdd(Call("c1"));

        _clock.Advance(PendingCallStore.RingTimeout);
        store.HasPending(_target, "c1", _caller).Should().BeFalse();
        store.TryAppend(_target, "c1", _caller, new("ice-candidate", "late")).Should().BeFalse();

        _clock.Advance(PendingCallStore.TombstoneLifetime - TimeSpan.FromSeconds(1));
        var delivery = store.TakeAll(_target);
        delivery.Calls.Should().BeEmpty();
        delivery.Tombstones.Single().CallId.Should().Be("c1");
    }

    [Fact]
    public void Tombstone_is_gone_after_its_lifetime()
    {
        var store = NewStore();
        store.TryAdd(Call("c1"));
        store.Cancel(_target, "c1", _caller).Should().NotBeNull();

        _clock.Advance(PendingCallStore.TombstoneLifetime);

        store.TakeAll(_target).Tombstones.Should().BeEmpty();
    }

    [Fact]
    public void Cancel_reports_the_push_once_also_after_the_ring_timed_out()
    {
        var store = NewStore();
        store.TryAdd(Call("live"));
        store.TryAdd(Call("timed-out"));
        _clock.Advance(TimeSpan.FromSeconds(10));
        store.Cancel(_target, "live", _caller).Should().NotBeNull();
        store.Cancel(_target, "live", _caller).Should().BeNull("the push went out already");

        // The caller app hangs up at its own 45 s timeout, right after the
        // store already turned the call into a tombstone: still one push.
        _clock.Advance(TimeSpan.FromSeconds(40));
        store.Cancel(_target, "timed-out", Guid.NewGuid()).Should().BeNull("only the caller cancels");
        store.Cancel(_target, "timed-out", _caller).Should().NotBeNull();
        store.Cancel(_target, "timed-out", _caller).Should().BeNull();

        store.TakeAll(_target).Tombstones.Select(t => t.CallId).Should().BeEquivalentTo(["live", "timed-out"]);
    }

    [Fact]
    public void Decline_removes_without_a_tombstone()
    {
        var store = NewStore();
        store.TryAdd(Call("c1"));

        store.Decline(_target, "c1")!.CallerDeviceId.Should().Be(_caller);
        store.Decline(_target, "c1").Should().BeNull();

        var delivery = store.TakeAll(_target);
        delivery.Calls.Should().BeEmpty();
        delivery.Tombstones.Should().BeEmpty();
    }

    [Fact]
    public void Decline_still_finds_a_call_delivered_on_connect_until_the_ring_timeout()
    {
        // The app must connect to call DeclinePendingCall, and connecting
        // already delivered the offer: the decline must still reach the caller.
        var store = NewStore();
        store.TryAdd(Call("c1"));
        store.TryAdd(Call("c2", Guid.NewGuid()));
        store.TakeAll(_target).Calls.Should().HaveCount(2);

        store.Decline(_target, "c1")!.CallerDeviceId.Should().Be(_caller);
        store.HasPending(_target, "c2", _caller).Should().BeFalse("delivered calls take no more signals");

        _clock.Advance(PendingCallStore.RingTimeout);
        store.Decline(_target, "c2").Should().BeNull();
        store.TakeAll(_target).Tombstones.Should().BeEmpty("a delivered call that times out is not a missed call here");
    }
}
