package main

import (
	"bytes"
	"crypto/hmac"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/mattermost/mattermost/server/public/plugin"
)

// These are packaged from the same, reviewed Korean board sources at build time.
//
//go:embed board-ui/*
var assets embed.FS

const pluginID = "com.hermes.research-board"
const maxBytes = 21 * 1024 * 1024

var idPattern = regexp.MustCompile(`^[a-z0-9]{26}$`)
var secretPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

type configuration struct {
	BridgeURL      string
	BridgeSecret   string
	HomeChannelID  string
	AllowedUserIDs string
}

type Plugin struct{ plugin.MattermostPlugin }

func bridgeURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, errors.New("invalid bridge URL")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1024 || port > 65535 || u.Scheme != "http" || u.Hostname() != "host.docker.internal" ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errors.New("only the local Docker Desktop bridge is allowed")
	}
	return u, nil
}

func (p *Plugin) config() (*configuration, error) {
	c := &configuration{}
	if err := p.API.LoadPluginConfiguration(c); err != nil {
		return nil, errors.New("보드 설정을 읽지 못했습니다")
	}
	if _, err := bridgeURL(c.BridgeURL); err != nil || !secretPattern.MatchString(c.BridgeSecret) || !idPattern.MatchString(c.HomeChannelID) {
		return nil, errors.New("마법사에서 보드 연결을 완료하세요")
	}
	ids := strings.Split(c.AllowedUserIDs, ",")
	if len(ids) == 0 || len(ids) > 100 {
		return nil, errors.New("열람 허용 사용자를 확인하세요")
	}
	for _, id := range ids {
		if !idPattern.MatchString(strings.TrimSpace(id)) {
			return nil, errors.New("열람 사용자 ID 오류")
		}
	}
	return c, nil
}

func listed(ids, user string) bool {
	for _, id := range strings.Split(ids, ",") {
		if strings.TrimSpace(id) == user {
			return true
		}
	}
	return false
}

func (p *Plugin) authorize(r *http.Request, c *configuration) bool {
	// Mattermost strips the caller's header and injects the authenticated identity.
	id := r.Header.Get("Mattermost-User-ID")
	if !idPattern.MatchString(id) || !listed(c.AllowedUserIDs, id) {
		return false
	}
	u, err := p.API.GetUser(id)
	if err != nil || u == nil || u.IsBot || u.DeleteAt != 0 {
		return false
	}
	m, err := p.API.GetChannelMember(c.HomeChannelID, id)
	return err == nil && m != nil
}

func headers(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Frame-Options", "SAMEORIGIN")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; object-src 'none'")
}

var boardClient = &http.Client{Timeout: 25 * time.Second, Transport: &http.Transport{Proxy: nil, ResponseHeaderTimeout: 20 * time.Second,
	MaxIdleConns: 8, MaxIdleConnsPerHost: 8, IdleConnTimeout: 30 * time.Second},
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}

func client() *http.Client {
	// Reuse one bounded transport for frequent board refreshes, not one idle
	// connection pool (and background goroutines) per request.
	return boardClient
}

func requestBridge(c *configuration, path, query string) (*http.Response, error) {
	u, err := bridgeURL(c.BridgeURL)
	if err != nil || !secretPattern.MatchString(c.BridgeSecret) {
		return nil, errors.New("invalid bridge configuration")
	}
	u.Path, u.RawQuery = path, query
	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Host = "127.0.0.1:" + u.Port()
	req.Header.Set("X-Hermes-Board-Secret", c.BridgeSecret)
	return client().Do(req)
}

func apiAllowed(path string) bool {
	return path == "/api/projects" || path == "/api/activity" || path == "/api/output" || path == "/api/log"
}

func (p *Plugin) ServeHTTP(_ *plugin.Context, w http.ResponseWriter, r *http.Request) {
	headers(w)
	if r.Method != http.MethodGet {
		http.Error(w, "읽기 전용입니다", http.StatusMethodNotAllowed)
		return
	}
	c, err := p.config()
	if err != nil {
		http.Error(w, "보드 연결 설정 미완료", http.StatusServiceUnavailable)
		return
	}
	installerProbe := r.URL.Path == "/installer-health" && hmac.Equal([]byte(r.Header.Get("X-Hermes-Setup-Probe")), []byte(c.BridgeSecret))
	if !installerProbe && !p.authorize(r, c) {
		http.Error(w, "이 연구 보드를 열람할 권한이 없습니다", http.StatusForbidden)
		return
	}
	if r.URL.Path == "/access" {
		channel, appErr := p.API.GetChannel(c.HomeChannelID)
		if appErr != nil || channel == nil {
			http.Error(w, "연구 채널 확인 실패", 503)
			return
		}
		team, appErr := p.API.GetTeam(channel.TeamId)
		if appErr != nil || team == nil {
			http.Error(w, "연구 팀 확인 실패", 503)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]string{"board_url": "/" + team.Name + "/" + pluginID + "/board", "channel_url": "/" + team.Name + "/channels/" + channel.Name})
		return
	}
	if r.URL.Path == "/health" || r.URL.Path == "/installer-health" {
		resp, err := requestBridge(c, "/health", "")
		if err != nil {
			http.Error(w, "로컬 보드 연결 대기", 503)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			http.Error(w, "로컬 보드 확인 실패", 503)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.Copy(w, io.LimitReader(resp.Body, 4096))
		return
	}
	path := r.URL.Path
	static := map[string]string{"/board/": "index.html", "/board/app.js": "app.js", "/board/app.css": "app.css"}
	if file, ok := static[path]; ok {
		raw, err := assets.ReadFile("board-ui/" + file)
		if err != nil {
			http.Error(w, "보드 파일 없음", 503)
			return
		}
		mime := map[string]string{"index.html": "text/html", "app.js": "text/javascript", "app.css": "text/css"}[file]
		w.Header().Set("Content-Type", mime+"; charset=utf-8")
		_, _ = w.Write(raw)
		return
	}
	if !strings.HasPrefix(path, "/board/") || !apiAllowed(strings.TrimPrefix(path, "/board")) || len(r.URL.RawQuery) > 16384 {
		http.NotFound(w, r)
		return
	}
	resp, err := requestBridge(c, strings.TrimPrefix(path, "/board"), r.URL.RawQuery)
	if err != nil {
		http.Error(w, "로컬 보드에 연결하지 못했습니다. 마법사에서 보드 연결을 확인하세요.", 503)
		return
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil || len(raw) > maxBytes {
		http.Error(w, "보드 응답 크기 또는 읽기 오류", 502)
		return
	}
	if resp.StatusCode != 200 {
		http.Error(w, "보드 연결·문서 버전을 다시 확인하세요", resp.StatusCode)
		return
	}
	for _, h := range []string{"Content-Type", "Content-Disposition"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	_, _ = w.Write(raw)
}

func main() {
	// Installer-only probe. A secret arrives via stdin, never command arguments.
	if len(os.Args) == 2 && os.Args[1] == "--probe" {
		var c configuration
		err := json.NewDecoder(io.LimitReader(os.Stdin, 8192)).Decode(&c)
		if err != nil {
			os.Exit(2)
		}
		r, err := requestBridge(&c, "/health", "")
		if err != nil {
			os.Exit(3)
		}
		defer r.Body.Close()
		raw, err := io.ReadAll(io.LimitReader(r.Body, 4096))
		if err != nil || r.StatusCode != 200 || !bytes.Contains(raw, []byte(`"ready": true`)) && !bytes.Contains(raw, []byte(`"ready":true`)) {
			os.Exit(4)
		}
		_, _ = os.Stdout.Write([]byte("{\"ready\":true}\n"))
		return
	}
	plugin.ClientMain(&Plugin{})
}
