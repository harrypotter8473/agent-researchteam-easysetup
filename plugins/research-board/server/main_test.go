package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
)

type fakeAPI struct {
	plugin.API
	c      configuration
	member bool
	bot    bool
}

func (f *fakeAPI) LoadPluginConfiguration(target interface{}) error {
	raw, _ := json.Marshal(f.c)
	return json.Unmarshal(raw, target)
}
func (f *fakeAPI) GetUser(id string) (*model.User, *model.AppError) {
	return &model.User{Id: id, IsBot: f.bot}, nil
}
func (f *fakeAPI) GetChannelMember(channel, user string) (*model.ChannelMember, *model.AppError) {
	if !f.member {
		return nil, model.NewAppError("test", "denied", nil, "", 403)
	}
	return &model.ChannelMember{ChannelId: channel, UserId: user}, nil
}
func (f *fakeAPI) GetChannel(id string) (*model.Channel, *model.AppError) {
	return &model.Channel{Id: id, TeamId: strings.Repeat("t", 26), Name: "agents"}, nil
}
func (f *fakeAPI) GetTeam(id string) (*model.Team, *model.AppError) {
	return &model.Team{Id: id, Name: "research"}, nil
}
func fixture() (*Plugin, *fakeAPI) {
	f := &fakeAPI{member: true, c: configuration{BridgeURL: "http://host.docker.internal:56789", BridgeSecret: strings.Repeat("a", 64), HomeChannelID: strings.Repeat("c", 26), AllowedUserIDs: strings.Repeat("u", 26)}}
	p := &Plugin{}
	p.SetAPI(f)
	return p, f
}
func TestBridgeTargetAllowlist(t *testing.T) {
	for _, target := range []string{"https://host.docker.internal:4444", "http://localhost:4444", "http://127.0.0.1:4444", "http://example.org:4444", "http://host.docker.internal:4444/private", "http://u:p@host.docker.internal:4444", "http://host.docker.internal:80", "http://host.docker.internal:4444?x=1"} {
		if _, err := bridgeURL(target); err == nil {
			t.Fatalf("accepted %s", target)
		}
	}
	if _, err := bridgeURL("http://host.docker.internal:56789"); err != nil {
		t.Fatal(err)
	}
}
func TestReadPermissionsAndStaticPaths(t *testing.T) {
	for _, tc := range []struct {
		name, method, path, user string
		member, bot              bool
		want                     int
	}{
		{"anonymous", "GET", "/board/", "", true, false, 403},
		{"unlisted", "GET", "/board/", strings.Repeat("z", 26), true, false, 403},
		{"not-member", "GET", "/board/", strings.Repeat("u", 26), false, false, 403},
		{"bot", "GET", "/board/", strings.Repeat("u", 26), true, true, 403},
		{"cannot-approve", "POST", "/board/api/approve", strings.Repeat("u", 26), true, false, 405},
		{"private-api", "GET", "/board/api/config", strings.Repeat("u", 26), true, false, 404},
		{"member-page", "GET", "/board/", strings.Repeat("u", 26), true, false, 200},
		{"member-css", "GET", "/board/app.css", strings.Repeat("u", 26), true, false, 200},
		{"member-js", "GET", "/board/app.js", strings.Repeat("u", 26), true, false, 200},
		{"member-access", "GET", "/access", strings.Repeat("u", 26), true, false, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p, f := fixture()
			f.member = tc.member
			f.bot = tc.bot
			r := httptest.NewRequest(tc.method, tc.path, nil)
			r.Header.Set("Mattermost-User-ID", tc.user)
			w := httptest.NewRecorder()
			p.ServeHTTP(nil, w, r)
			if w.Code != tc.want {
				t.Fatalf("got %d want %d", w.Code, tc.want)
			}
			if strings.Contains(w.Body.String(), f.c.BridgeSecret) || strings.Contains(w.Body.String(), f.c.BridgeURL) {
				t.Fatal("secret exposed")
			}
			if w.Header().Get("X-Frame-Options") != "SAMEORIGIN" {
				t.Fatal("unsafe embedding")
			}
		})
	}
}
func TestAccessRouteAndRelativeAssets(t *testing.T) {
	p, f := fixture()
	r := httptest.NewRequest("GET", "/access", nil)
	r.Header.Set("Mattermost-User-ID", f.c.AllowedUserIDs)
	w := httptest.NewRecorder()
	p.ServeHTTP(nil, w, r)
	if !strings.Contains(w.Body.String(), "/research/com.hermes.research-board/board") {
		t.Fatal("not a team route")
	}
	r = httptest.NewRequest("GET", "/board/", nil)
	r.Header.Set("Mattermost-User-ID", f.c.AllowedUserIDs)
	w = httptest.NewRecorder()
	p.ServeHTTP(nil, w, r)
	if strings.Contains(w.Body.String(), `src="/app.js"`) || strings.Contains(w.Body.String(), `href="/app.css"`) {
		t.Fatal("assets escape plugin prefix")
	}
}
func TestMissingConfigIsNotReady(t *testing.T) {
	p, f := fixture()
	f.c.BridgeSecret = ""
	w := httptest.NewRecorder()
	p.ServeHTTP(nil, w, httptest.NewRequest("GET", "/access", nil))
	if w.Code != 503 {
		t.Fatal("missing settings were treated as ready")
	}
}

func TestProbeSecretCannotReadResearch(t *testing.T) {
	p, f := fixture()
	for _, path := range []string{"/access", "/board/", "/board/api/projects", "/board/api/output?path=secret"} {
		r := httptest.NewRequest("GET", path, nil)
		r.Header.Set("X-Hermes-Setup-Probe", f.c.BridgeSecret)
		w := httptest.NewRecorder()
		p.ServeHTTP(nil, w, r)
		if w.Code != 403 {
			t.Fatalf("installer credential read %s: %d", path, w.Code)
		}
	}
	r := httptest.NewRequest("GET", "/installer-health", nil)
	r.Header.Set("X-Hermes-Setup-Probe", strings.Repeat("b", 64))
	w := httptest.NewRecorder()
	p.ServeHTTP(nil, w, r)
	if w.Code != 403 {
		t.Fatal("invalid probe secret was accepted")
	}
}

func TestRefreshReusesBoundedHTTPTransport(t *testing.T) {
	if client() != client() {
		t.Fatal("one transport was created per refresh")
	}
	transport := client().Transport.(*http.Transport)
	if transport.IdleConnTimeout <= 0 || transport.MaxIdleConns != 8 || transport.Proxy != nil {
		t.Fatal("unbounded or proxy-enabled transport")
	}
}
