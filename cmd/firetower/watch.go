package main

import (
	"bufio"
	"encoding/json"
	"os"
	"time"
)

// The feed: what every board reads, locally or over ssh. One JSON object per
// line:
//
//	{"type":"hello","v":1,"version":"firetower v0.1.0 (darwin/arm64)"}
//	{"type":"lookout","lookout":{...a View...}}   every lookout, then each change
//	{"type":"gone","id":"district/tower/name"}    a lookout left
//	{"type":"sync","at":"...","ids":[...]}         the full set, after every full send
//
// It sends everything, then a sync; then a line for every change, including
// the ones nobody writes (a lookout past its next_by going to no word, one
// past its until standing down); and every 60s everything again and a sync, so a reader knows the feed is alive and
// can drop anything it missed the gone of.
type Event struct {
	Type    string     `json:"type"`
	V       int        `json:"v,omitempty"`
	Version string     `json:"version,omitempty"`
	At      *time.Time `json:"at,omitempty"`
	Lookout *View      `json:"lookout,omitempty"`
	ID      string     `json:"id,omitempty"`
	IDs     *[]string  `json:"ids,omitempty"` // always there on a sync, even empty
}

const (
	feedVersion = 1
	resendEvery = 60 * time.Second
	pollEvery   = time.Second
)

func cmdWatch(args []string) error {
	f, err := parseFlags(args, map[string]bool{"json": false, "once": false}, false)
	const u = "watch --json [--once]"
	if err != nil {
		return bad(u, err)
	}
	if len(f.pos) != 0 || !f.has("json") {
		return badf(u, "the feed is JSON lines, for boards: say --json (firetower ls is for people)")
	}
	out := bufio.NewWriter(os.Stdout)
	enc := json.NewEncoder(out)
	emit := func(e Event) error { return enc.Encode(e) }
	flush := func() error { return out.Flush() }
	return feed(stateDir(), f.has("once"), emit, flush, nil)
}

// feed runs the feed over dir until a write fails (the reader went away) or
// stop closes.
func feed(dir string, once bool, emit func(Event) error, flush func() error, stop <-chan struct{}) error {
	if err := emit(Event{Type: "hello", V: feedVersion, Version: versionString()}); err != nil {
		return nil
	}
	last := map[string]string{}
	full := func() error {
		at := now()
		vs := localViews(dir, at, false)
		ids := make([]string, 0, len(vs))
		next := map[string]string{}
		for i := range vs {
			v := vs[i]
			b, _ := json.Marshal(v)
			next[v.ID] = string(b)
			ids = append(ids, v.ID)
			if err := emit(Event{Type: "lookout", Lookout: &v}); err != nil {
				return err
			}
		}
		last = next
		if err := emit(Event{Type: "sync", At: &at, IDs: &ids}); err != nil {
			return err
		}
		return flush()
	}
	if err := full(); err != nil || once {
		return nil
	}
	tick := time.NewTicker(pollEvery)
	defer tick.Stop()
	lastFull := time.Now()
	for {
		select {
		case <-stop:
			return nil
		case <-tick.C:
		}
		if time.Since(lastFull) >= resendEvery {
			if full() != nil {
				return nil
			}
			lastFull = time.Now()
			continue
		}
		vs := localViews(dir, now(), false)
		next := map[string]string{}
		for i := range vs {
			v := vs[i]
			b, _ := json.Marshal(v)
			s := string(b)
			next[v.ID] = s
			if last[v.ID] != s {
				if emit(Event{Type: "lookout", Lookout: &v}) != nil {
					return nil
				}
			}
		}
		for id := range last {
			if _, ok := next[id]; !ok {
				if emit(Event{Type: "gone", ID: id}) != nil {
					return nil
				}
			}
		}
		last = next
		if flush() != nil {
			return nil
		}
	}
}
