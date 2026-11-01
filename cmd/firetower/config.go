package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// Config is ~/.config/firetower/config.toml (or $FIRETOWER_CONFIG). Most
// people need none: the defaults are "main", and a board shows this
// machine's lookouts.
type Config struct {
	DefaultDistrict string   `toml:"default_district"`
	DefaultTower    string   `toml:"default_tower"`
	Board           Board    `toml:"board"`
	Sources         []Source `toml:"source"`

	path string
}

type Board struct {
	Port  int    `toml:"port"`
	UI    string `toml:"ui"`
	Local *bool  `toml:"local"` // false: show only the sources, not this machine's own lookouts
}

// A Source is another feed a board shows: any command that prints
// `firetower watch --json`, usually over ssh.
type Source struct {
	Name     string   `toml:"name"`
	Command  []string `toml:"command"`
	District string   `toml:"district"`
	Act      []string `toml:"act"`
}

const defaultPort = 7480

func configPath() string {
	if p := os.Getenv("FIRETOWER_CONFIG"); p != "" {
		return p
	}
	if d := os.Getenv("XDG_CONFIG_HOME"); d != "" {
		return filepath.Join(d, "firetower", "config.toml")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "firetower", "config.toml")
}

// loadConfig reads the config. A missing file is no config. A broken one is
// an error the caller decides about: a report falls back to the defaults
// (a check that can't report is worse than one in the wrong tower), a board
// refuses to start.
func loadConfig() (*Config, error) {
	c := &Config{path: configPath()}
	b, err := os.ReadFile(c.path)
	if err != nil {
		if os.IsNotExist(err) {
			return c.fill(), nil
		}
		return c.fill(), err
	}
	md, err := toml.Decode(string(b), c)
	if err != nil {
		return (&Config{path: c.path}).fill(), fmt.Errorf("%s: %v", c.path, err)
	}
	if und := md.Undecoded(); len(und) > 0 {
		keys := make([]string, len(und))
		for i, k := range und {
			keys[i] = k.String()
		}
		return (&Config{path: c.path}).fill(), fmt.Errorf("%s: unknown setting %s", c.path, strings.Join(keys, ", "))
	}
	if err := c.check(); err != nil {
		return (&Config{path: c.path}).fill(), fmt.Errorf("%s: %v", c.path, err)
	}
	return c.fill(), nil
}

func (c *Config) fill() *Config {
	if c.DefaultDistrict == "" {
		c.DefaultDistrict = "main"
	}
	if c.DefaultTower == "" {
		c.DefaultTower = "main"
	}
	if c.Board.Port == 0 {
		c.Board.Port = defaultPort
	}
	return c
}

func (c *Config) check() error {
	if c.DefaultDistrict != "" {
		if err := checkName("default_district", c.DefaultDistrict); err != nil {
			return err
		}
	}
	if c.DefaultTower != "" {
		if err := checkName("default_tower", c.DefaultTower); err != nil {
			return err
		}
	}
	if c.Board.Port < 0 || c.Board.Port > 65535 {
		return fmt.Errorf("board.port %d is not a port", c.Board.Port)
	}
	seen := map[string]bool{}
	for i, s := range c.Sources {
		if err := checkName(fmt.Sprintf("source %d's name", i+1), s.Name); err != nil {
			return err
		}
		if seen[s.Name] {
			return fmt.Errorf("two sources named %q", s.Name)
		}
		seen[s.Name] = true
		if len(s.Command) == 0 {
			return fmt.Errorf("source %q has no command", s.Name)
		}
		if s.District != "" {
			if err := checkName("source "+s.Name+"'s district", s.District); err != nil {
				return err
			}
		}
	}
	return nil
}

func (c *Config) showLocal() bool { return c.Board.Local == nil || *c.Board.Local }

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	return p
}
