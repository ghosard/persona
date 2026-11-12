package assistant

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/nwverse/persona/server/internal/proto"
)

// Reusing an agent whose earlier card is closed creates a continuation, not an unrelated card. Both directions are
// visible in GET /api/v1/todos, with the hand-over note carried on the old card (#5732).
func TestAgentSuperviseAfterCloseLinksTheTakeoverLineage(t *testing.T) {
	s, f, old := newSupervisedService(t)
	agentTurn(s, f, proto.StatusWorking, "", 0)
	raw, _ := json.Marshal(map[string]any{"todo_id": old.ID, "verdict": "accepted", "note": "Spec 已验收"})
	if _, err := s.runTool(context.Background(), "server", "conv1", "task_review", raw); err != nil {
		t.Fatal(err)
	}
	if got := todoNow(s, old.ID); got.DoneAt == nil {
		t.Fatal("the old card is not closed")
	}
	machine, ok := s.device(context.Background(), "box")
	if !ok {
		t.Fatal("task machine is missing")
	}
	agent, ok := s.session(context.Background(), "box", "s1")
	if !ok {
		t.Fatal("task agent is missing")
	}
	if _, made, err := s.adoptAgent(context.Background(), "conv1", machine, agent, "接手实现", "", "换 Agent 接手实现", nil, 0, true); err != nil || !made {
		t.Fatalf("adopt after close: made %v, err %v", made, err)
	}
	var current Todo
	for _, td := range s.todosOf(context.Background(), "*") {
		if td.DoneAt == nil {
			current = td
		}
	}
	if current.ID == "" || current.ID == old.ID {
		t.Fatalf("no new takeover card after %+v", old)
	}
	listed := listedTodos(t, s)
	steps := func(id string) []map[string]any {
		raw, _ := json.Marshal(listed[id]["lineage"])
		var out []map[string]any
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	var oldBefore, newBefore map[string]any
	for _, step := range steps(old.ID) {
		if step["todo_id"] == old.ID {
			oldBefore = step
		}
	}
	for _, step := range steps(current.ID) {
		if step["todo_id"] == current.ID {
			newBefore = step
		}
	}
	if oldBefore["superseded_by"] != current.ID {
		t.Fatalf("old lineage = %+v", steps(old.ID))
	}
	if newBefore["continues"] != old.ID || newBefore["current"] != true {
		t.Fatalf("new lineage = %+v", steps(current.ID))
	}
	// The assistant's text snapshot exposes the same two directions and their result links, not only the API (#5732).
	shots := map[string]bool{}
	for _, task := range s.snapshotTasks(context.Background(), "https://hub.example.com") {
		shots[task.ID] = true
		switch task.ID {
		case old.ID:
			if task.SupersededBy != current.ID || task.SupersededByLink != "https://hub.example.com/todos?id="+current.ID {
				t.Fatalf("old snapshot = %+v", task)
			}
		case current.ID:
			if task.Continues != old.ID || task.ContinuesLink != "https://hub.example.com/todos?id="+old.ID {
				t.Fatalf("new snapshot = %+v", task)
			}
		}
	}
	if !shots[old.ID] || !shots[current.ID] {
		t.Fatalf("snapshot is missing a lineage card: %v", shots)
	}
}
