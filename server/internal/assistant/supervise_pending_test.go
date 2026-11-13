package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/nwverse/persona/server/internal/db"
	"github.com/nwverse/persona/server/internal/proto"
)

// storedSupervisePending reads the durable outbox without depending on its in-memory representation.
func storedSupervisePending(t *testing.T, s *Service) map[string]superviseSignal {
	t.Helper()
	var state struct {
		Pending map[string]superviseSignal `json:"supervise_pending"`
	}
	if _, err := s.store().Setting(context.Background(), relayKey, &state); err != nil {
		t.Fatal(err)
	}
	return state.Pending
}

// A needs-user state produces no new watch signal. Its gathered notification must therefore survive a restart before
// the first digest, reach main, and leave the durable outbox only after real delivery or queue admission (#5732).
func TestNeedsUserPendingSurvivesRestartBeforeDigest(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, f, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	ctx := context.Background()
	if _, _, err := s.updateSupervision(ctx, todo.ID, func(v *Supervision) bool {
		v.State = reviewNeedsUser
		return true
	}); err != nil {
		t.Fatal(err)
	}
	g := superviseSignal{Todo: todo.ID, Kind: sigIdle, Key: "owner-wait-1", Detail: "要用户决定：选择发布方式", At: time.Now()}
	s.signal(g)
	if got := storedSupervisePending(t, s)[g.id()]; got.Key != g.Key {
		t.Fatalf("the gathered needs-user signal was not persisted: %+v", got)
	}

	// A process restart loses the in-memory book and relay's loaded mark, not the shared store.
	s.supervise = superviseBook{}
	s.superviseTimes = superviseTimings{gather: 1, every: 1, urgent: 1} // due immediately for the post-restart digest
	s.relays.mu.Lock()
	s.relays.loaded = false
	s.relays.mu.Unlock()
	s.sendDigest(ctx)
	if got := strings.Join(f.noticesTo("conv1"), "\n"); !strings.Contains(got, todo.ID) || !strings.Contains(got, "选择发布方式") {
		t.Fatalf("the restored needs-user signal was not delivered to main:\n%s", got)
	}
	if got := storedSupervisePending(t, s); len(got) != 0 {
		t.Fatalf("the delivered signal stayed in the durable outbox: %+v", got)
	}
}

// A late acknowledgment for an older stretch cannot delete the newer one gathered under the same signal id.
func TestPendingAckKeepsNewerStretch(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, _, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	old := superviseSignal{Todo: todo.ID, Kind: sigIdle, Key: "old", At: time.Now()}
	newer := superviseSignal{Todo: todo.ID, Kind: sigIdle, Key: "new", At: time.Now()}
	s.signal(old)
	s.signal(newer)
	s.ackSupervisePending([]superviseSignal{old})
	if got := storedSupervisePending(t, s)[newer.id()]; got.Key != newer.Key {
		t.Fatalf("the old acknowledgment removed the newer stretch: %+v", got)
	}
}

// A task leader's direct worker delivery uses the same durable acknowledgment as a conversation digest.
func TestTaskLeaderDeliveryAcknowledgesPending(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, f, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	g := superviseSignal{Todo: todo.ID, Kind: sigStalled, Key: "worker-stall", At: time.Now()}
	s.signal(g)
	f.setSessions("box", proto.Session{MachineID: "box", SessionID: "s1", Status: proto.StatusWorking, State: proto.StateWorking})
	lead := TodoAgent{MachineID: "box", SessionID: "s1"}
	if !s.deliverToLeaderAgent(context.Background(), lead, []superviseSignal{g}, testWeb, time.Now(), time.Time{}) {
		t.Fatal("the online task leader did not accept its worker signal")
	}
	if got := storedSupervisePending(t, s); len(got) != 0 {
		t.Fatalf("the worker signal stayed pending after delivery: %+v", got)
	}
}

// Starting an offline leader's resume is not delivery: the outbox clears only after the blocked real send completes.
func TestOfflineTaskLeaderAcknowledgesOnlyAfterSend(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, f, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	g := superviseSignal{Todo: todo.ID, Kind: sigStalled, Key: "offline-worker-stall", At: time.Now()}
	s.signal(g)
	f.setSessions("box", proto.Session{MachineID: "box", SessionID: "s1", Status: proto.StatusOffline})
	started, release := make(chan struct{}), make(chan struct{})
	f.answerNode(DeviceSessionSend, func(_ string, _ json.RawMessage) (any, error) {
		close(started)
		<-release
		return map[string]any{"ok": true}, nil
	})
	lead := TodoAgent{MachineID: "box", SessionID: "s1"}
	if !s.deliverToLeaderAgent(context.Background(), lead, []superviseSignal{g}, testWeb, time.Now(), time.Time{}) {
		t.Fatal("the offline leader's resume was not started")
	}
	<-started
	if got := storedSupervisePending(t, s)[g.id()]; got.Key != g.Key {
		t.Fatal("the offline leader was acknowledged before its real send")
	}
	close(release)
	waitFor(t, "the offline leader's real-send acknowledgment", func() bool { return len(storedSupervisePending(t, s)) == 0 })
}

// An unreachable leader's signal is delivered as a decision above it; the original worker signal must not replay too.
func TestUnreachableLeaderEscalationReplacesPending(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, f, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: 1, every: 1, urgent: 1}
	ctx := context.Background()
	if _, _, err := s.updateSupervision(ctx, todo.ID, func(v *Supervision) bool {
		v.Supervisor = "box/s1"
		return true
	}); err != nil {
		t.Fatal(err)
	}
	released := time.Now()
	putTodo(s, Todo{ID: "leader-task", Origin: "conv1", Supervision: &Supervision{Supervisor: "conv1"},
		Agents: []TodoAgent{{MachineID: "box", SessionID: "s1", Source: sourceLeader, ReleasedAt: &released}}})
	f.setSessions("box")
	g := superviseSignal{Todo: todo.ID, Kind: sigStalled, Key: "unreachable-leader", At: time.Now()}
	s.signal(g)
	s.sendDigest(ctx)
	if got := strings.Join(f.noticesTo("conv1"), "\n"); !strings.Contains(got, todo.ID) || !strings.Contains(got, "cannot be reached") {
		t.Fatalf("the leader's decision did not reach main:\n%s", got)
	}
	if got := storedSupervisePending(t, s); len(got) != 0 {
		t.Fatalf("the escalated worker signal remained for a duplicate restart delivery: %+v", got)
	}
}

// A retry after the first resume failure is a real delivery too, and acknowledges the worker's durable signal.
func TestLeaderRetrySuccessAcknowledgesPending(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, f, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	g := superviseSignal{Todo: todo.ID, Kind: sigStalled, Key: "retry-leader", At: time.Now()}
	s.signal(g)
	setSettings(t, s, func(v *Settings) { v.Main = "" }) // nobody above: only the leader retry can deliver it
	calls := 0
	f.answerNode(DeviceSessionSend, func(_ string, _ json.RawMessage) (any, error) {
		calls++
		if calls == 1 {
			return nil, errors.New("resume failed")
		}
		return map[string]any{"ok": true}, nil
	})
	s.leaderResume = time.Millisecond
	lead := TodoAgent{MachineID: "box", SessionID: "s1"}
	s.escalateLeaderMessage(lead, []superviseSignal{g}, "worker supervision")
	waitFor(t, "the successful leader retry's acknowledgment", func() bool { return len(storedSupervisePending(t, s)) == 0 })
}

// Queue admission and outbox acknowledgment are one relay-state write. An older crash state with both is reconciled.
func TestQueuedSupervisionAndOutboxAreAtomic(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, _, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	g := superviseSignal{Todo: todo.ID, Kind: sigStalled, Key: "queued-once", At: time.Now()}
	s.signal(g)
	signals := []superviseSignal{g}
	if s.queueRelay("conv1", relayMsg{Tool: superviseTool, Text: "queued", Signals: &signals, At: time.Now()}) != 1 {
		t.Fatal("the supervision message was not queued")
	}
	if got := storedSupervisePending(t, s); len(got) != 0 {
		t.Fatalf("queue admission left the same signal in the outbox: %+v", got)
	}
	// Reproduce the pre-fix crash window: both the durable queue and outbox contain the exact stretch.
	s.updateSupervisePending(func(pending map[string]superviseSignal) { pending[g.id()] = g })
	s.supervise = superviseBook{}
	s.relays.mu.Lock()
	s.relays.loaded = false
	s.relays.mu.Unlock()
	s.restoreSupervisePending(context.Background())
	if got := storedSupervisePending(t, s); len(got) != 0 {
		t.Fatalf("the queued signal was not reconciled from the outbox: %+v", got)
	}
	s.supervise.mu.Lock()
	_, restored := s.supervise.pending[g.id()]
	s.supervise.mu.Unlock()
	if restored {
		t.Fatal("the queued signal was restored for a second delivery")
	}
}

// A real send succeeded but its ACK was lost. On restart an offline dedup hit retries rather than stranding the outbox.
func TestOfflineLeaderDedupHitRestoresPending(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, f, todo := newSupervisedServiceOn(t, st)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	g := superviseSignal{Todo: todo.ID, Kind: sigStalled, Key: "dedup-after-restart", At: time.Now()}
	f.setSessions("box", proto.Session{MachineID: "box", SessionID: "s1", Status: proto.StatusWorking, State: proto.StateWorking})
	s.signal(g)
	lead := TodoAgent{MachineID: "box", SessionID: "s1"}
	if !s.deliverToLeaderAgent(context.Background(), lead, []superviseSignal{g}, testWeb, time.Now(), time.Time{}) {
		t.Fatal("the initial real send failed")
	}
	s.updateSupervisePending(func(pending map[string]superviseSignal) { pending[g.id()] = g }) // ACK lost after that send
	f.setSessions("box", proto.Session{MachineID: "box", SessionID: "s1", Status: proto.StatusOffline})
	s.supervise = superviseBook{}
	s.relays.mu.Lock()
	s.relays.loaded = false
	s.relays.mu.Unlock()
	s.restoreSupervisePending(context.Background())
	s.supervise.mu.Lock()
	s.supervise.pending = map[string]superviseSignal{} // sendDigest took the stretch out for this delivery attempt
	s.supervise.mu.Unlock()
	if s.deliverToLeaderAgent(context.Background(), lead, []superviseSignal{g}, testWeb, time.Now(), time.Time{}) {
		t.Fatal("a deduplicated offline delivery unexpectedly ran")
	}
	s.supervise.mu.Lock()
	_, restored := s.supervise.pending[g.id()]
	s.supervise.mu.Unlock()
	if !restored || storedSupervisePending(t, s)[g.id()].Key != g.Key {
		t.Fatal("the offline dedup hit stranded the signal instead of retrying it")
	}
}

// /stop silences a reporting task's gathered notices even when the manager restarts before the stop (#3308, #5732).
func TestStopReportingDropsPersistedPending(t *testing.T) {
	st := planUpdateStore{&planMemStore{memStore: &memStore{}, plans: map[string]db.TaskPlanRow{}}}
	s, f := newQuietServiceOn(t, st)
	ctx := context.Background()
	f.known["lark1"] = true
	f.setSessions("server", proto.Session{SessionID: "conv1", MachineID: "server", Assistant: true, Status: proto.StatusIdle},
		proto.Session{SessionID: "lark1", MachineID: "server", Assistant: true, Status: proto.StatusWorking})
	s.markReporter(ctx, "server", "lark1")
	if _, err := s.toolTaskPlan(ctx, "lark1", planArgs(true)); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the reporting task's agent", func() bool { return len(onlyTodo(s).Agents) == 1 })
	agentTurn(s, f, proto.StatusWorking, "", 0)
	s.superviseTimes = superviseTimings{gather: time.Hour, every: time.Hour, urgent: time.Hour}
	todo := onlyTodo(s)
	g := superviseSignal{Todo: todo.ID, Kind: sigUnjudged, Key: "before-stop", At: time.Now()}
	s.signal(g)
	if got := storedSupervisePending(t, s)[g.id()]; got.Key != g.Key {
		t.Fatal("the test signal was not persisted")
	}
	s.supervise = superviseBook{}
	s.relays.mu.Lock()
	s.relays.loaded = false
	s.relays.mu.Unlock()
	if w := serve(s, "POST", "/api/v1/assistant/conversations/lark1/stop", ""); w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if got := storedSupervisePending(t, s); len(got) != 0 {
		t.Fatalf("the stopped task's persisted signal survived: %+v", got)
	}
}
