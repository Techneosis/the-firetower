package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// The files are the state: one JSON file per lookout, no daemon, no index.
// Every write holds one lock for the whole directory while it reads and
// replaces a file, so two reports at once can't lose an owned field. Writes
// are rare (a check every few minutes), so one lock costs nothing.

func stateDir() string {
	if d := os.Getenv("FIRETOWER_DIR"); d != "" {
		return d
	}
	if d := os.Getenv("XDG_STATE_HOME"); d != "" {
		return filepath.Join(d, "firetower")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "firetower")
}

func lookoutPath(dir, district, tower, name string) string {
	return filepath.Join(dir, district, tower, name+".json")
}

// lockDir takes the directory's write lock, creating the directory (private:
// messages are on screen, but they're nobody else's business).
func lockDir(dir string) (func(), error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}

// loadLookout reads one file. The path is the truth for where a lookout
// lives: a file whose fields disagree with its place is read as its place.
func loadLookout(path string) (*Lookout, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var l Lookout
	if err := json.Unmarshal(b, &l); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	place(&l, path)
	return &l, nil
}

func place(l *Lookout, path string) {
	l.Name = strings.TrimSuffix(filepath.Base(path), ".json")
	l.Tower = filepath.Base(filepath.Dir(path))
	l.District = filepath.Base(filepath.Dir(filepath.Dir(path)))
}

// saveLookout writes a file atomically: a temp file beside it, synced, then
// renamed over it, so a reader never sees half a report.
func saveLookout(dir string, l *Lookout) error {
	path := lookoutPath(dir, l.District, l.Tower, l.Name)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(l, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+l.Name+".json.tmp*")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(append(b, '\n'))
	if werr == nil {
		werr = tmp.Sync()
	}
	if cerr := tmp.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Rename(tmp.Name(), path)
	}
	if werr != nil {
		os.Remove(tmp.Name())
	}
	return werr
}

// A broken file is one the Firetower can't read: it shows as fire, never as
// nothing, because a report nobody can read is not a quiet one.
type broken struct {
	District, Tower, Name, Err string
	Since                      *time.Time // when the file was last written
}

// loadAll reads every lookout under dir. Anything that isn't a lookout's
// place (hidden files, temp files, stray names) is skipped.
func loadAll(dir string) ([]*Lookout, []broken) {
	var out []*Lookout
	var bad []broken
	districts, _ := os.ReadDir(dir)
	for _, d := range districts {
		if !d.IsDir() || checkName("district", d.Name()) != nil {
			continue
		}
		towers, _ := os.ReadDir(filepath.Join(dir, d.Name()))
		for _, t := range towers {
			if !t.IsDir() || checkName("tower", t.Name()) != nil {
				continue
			}
			files, _ := os.ReadDir(filepath.Join(dir, d.Name(), t.Name()))
			for _, f := range files {
				n := f.Name()
				if !strings.HasSuffix(n, ".json") || !f.Type().IsRegular() {
					continue
				}
				name := strings.TrimSuffix(n, ".json")
				if checkName("lookout", name) != nil {
					continue
				}
				l, err := loadLookout(filepath.Join(dir, d.Name(), t.Name(), n))
				if err != nil {
					if !errors.Is(err, os.ErrNotExist) {
						b := broken{District: d.Name(), Tower: t.Name(), Name: name, Err: err.Error()}
						if info, ierr := f.Info(); ierr == nil {
							b.Since = tp(info.ModTime().UTC().Truncate(time.Second))
						}
						bad = append(bad, b)
					}
					continue
				}
				out = append(out, l)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID() < out[j].ID() })
	return out, bad
}

// removeEmpty drops a tower's and a district's folders once their last
// lookout is gone: towers and districts exist only because lookouts name them.
func removeEmpty(dir, district, tower string) {
	if tower != "" {
		os.Remove(filepath.Join(dir, district, tower))
	}
	os.Remove(filepath.Join(dir, district))
}

// now is the clock. FIRETOWER_NOW pins it, for tests.
func now() time.Time {
	if s := os.Getenv("FIRETOWER_NOW"); s != "" {
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			return t.UTC()
		}
	}
	return time.Now().UTC().Truncate(time.Millisecond)
}

func tp(t time.Time) *time.Time { return &t }
