// Package main builds AventCore, a static library (go build -buildmode=c-archive)
// that runs aventproxy's WebRTC→RTSP bridge inside the macOS app.
//
// Swift talks to it through one JSON entry point:
//
//	AventCall({"method": "...", "params": {...}}) → {"ok": true, "result": ...}
//	                                              → {"ok": false, "error": "...", "code": "..."}
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unsafe"

	"avent-webrtc-bridge/pkg/core"
	"avent-webrtc-bridge/pkg/rtsp"
	"avent-webrtc-bridge/pkg/storage"
	"avent-webrtc-bridge/pkg/tuya"

	"github.com/rs/zerolog"
)

func main() {}

var (
	mu     sync.Mutex
	inited bool
	store  *storage.StorageManager
	server *rtsp.RTSPServer
)

type bridgeInfo struct {
	Port     int         `json:"port"`
	Talkback bool        `json:"talkback"`
	Cameras  []bridgeCam `json:"cameras"`
}

type bridgeCam struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
	URL  string `json:"url"`
}

//export AventInit
func AventInit(dir *C.char) *C.char {
	return respond(func() (any, error) {
		mu.Lock()
		defer mu.Unlock()
		if inited {
			return map[string]any{"ready": true}, nil
		}
		d := C.GoString(dir)
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
		// The bridge's storage lives in <cwd>/.tuya-data.
		if err := os.Chdir(d); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(filepath.Join(d, "bridge.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			return nil, err
		}
		zerolog.TimeFieldFormat = zerolog.TimeFormatUnixMs
		core.Logger = zerolog.New(zerolog.MultiLevelWriter(
			&zerolog.ConsoleWriter{Out: f, NoColor: true, TimeFormat: "15:04:05.000"}, core.MemoryLog,
		)).Level(zerolog.DebugLevel).With().Timestamp().Logger()
		store, err = storage.NewStorageManager()
		if err != nil {
			return nil, err
		}
		inited = true
		return map[string]any{"ready": true, "log": f.Name()}, nil
	})
}

//export AventCall
func AventCall(req *C.char) *C.char {
	return respond(func() (any, error) {
		var r struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal([]byte(C.GoString(req)), &r); err != nil {
			return nil, err
		}
		switch r.Method {
		case "sendCode":
			return withParams(r.Params, sendCode)
		case "verify":
			return withParams(r.Params, verify)
		case "userInfo":
			return withParams(r.Params, userInfo)
		case "cameras":
			return withParams(r.Params, listCameras)
		case "deviceState":
			return withParams(r.Params, deviceStateOf)
		case "setDps":
			return withParams(r.Params, setDPS)
		case "startBridge":
			return withParams(r.Params, startBridge)
		case "stopBridge":
			mu.Lock()
			defer mu.Unlock()
			stopBridgeLocked()
			return map[string]any{"stopped": true}, nil
		}
		return nil, fmt.Errorf("unknown method %q", r.Method)
	})
}

// withParams decodes a method's JSON params and calls its handler.
func withParams[P, R any](raw json.RawMessage, fn func(P) (R, error)) (any, error) {
	var p P
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}
	return fn(p)
}

//export AventFree
func AventFree(p *C.char) { C.free(unsafe.Pointer(p)) }

func respond(fn func() (any, error)) *C.char {
	var out []byte
	func() {
		defer func() {
			if rec := recover(); rec != nil {
				out, _ = json.Marshal(map[string]any{"ok": false, "error": fmt.Sprint(rec), "code": "PANIC"})
			}
		}()
		res, err := fn()
		if err != nil {
			code := ""
			var ae *APIError
			if errors.As(err, &ae) {
				code = ae.Code
			}
			out, _ = json.Marshal(map[string]any{"ok": false, "error": err.Error(), "code": code})
			return
		}
		out, _ = json.Marshal(map[string]any{"ok": true, "result": res})
	}()
	return C.CString(string(out))
}

// freePort returns preferred when it is free on loopback, otherwise any free port.
func freePort(preferred int) (int, error) {
	if preferred > 0 {
		if l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", preferred)); err == nil {
			l.Close()
			return preferred, nil
		}
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// stopBridgeLocked stops the RTSP server. Callers hold mu.
func stopBridgeLocked() {
	if server != nil {
		core.Logger.Info().Msg("Stopping bridge")
		server.Stop()
		server = nil
	}
}

type startParams struct {
	Session Session  `json:"session"`
	Cameras []Camera `json:"cameras"`
	Port    int      `json:"port"`
	// Talkback asks the cameras for two-way audio, so a client can talk
	// through the stream. It makes a camera stop a playing lullaby and
	// restart it when the stream closes (aventproxy issue #72), so the app
	// turns it on only while the user wants to talk.
	Talkback bool `json:"talkback"`
}

// startBridge does what avent-webrtc-bridge's `addon` command does, minus the
// signal wait: it serves every camera from one RTSP server bound to loopback.
// A running bridge is replaced.
func startBridge(p startParams) (*bridgeInfo, error) {
	mu.Lock()
	defer mu.Unlock()
	if !inited {
		return nil, fmt.Errorf("AventInit was not called")
	}
	if len(p.Cameras) == 0 {
		return nil, fmt.Errorf("no camera to serve")
	}
	stopBridgeLocked()

	s := p.Session
	apiHost := tuya.NormalizeAPIHost(s.APIHost)
	client := tuya.NewMobileSDKClient(signingKey, s.SID, appKey, s.DeviceID, chKey)
	client.BaseURL = tuya.APIBaseURL(apiHost)
	client.Ecode = s.Ecode
	client.PartnerIdentity = s.Partner
	client.PackageName = packageName

	core.Logger.Info().Msgf("Tuya API host: %s", apiHost)
	user, err := client.GetUserInfo()
	if err != nil {
		return nil, fmt.Errorf("session check failed: %w", err)
	}
	client.UID = user.ID

	// Must equal storage.userKey("addon", email): the RTSP server finds a
	// camera's session through this key.
	userKey := "addon_" + strings.NewReplacer("@", "_at_", ".", "_").Replace(user.Email)
	if err := store.SaveUser("addon", user.Email, &tuya.SessionData{
		LoginResult: &tuya.LoginResult{Uid: user.ID, Email: user.Email, Nickname: user.Nickname, Domain: user.Domain},
		ServerHost:  apiHost, Region: "addon", UserEmail: user.Email,
	}); err != nil {
		core.Logger.Warn().Msgf("Could not save user session: %v", err)
	}

	port, err := freePort(p.Port)
	if err != nil {
		return nil, fmt.Errorf("no free port: %w", err)
	}
	info := &bridgeInfo{Port: port, Talkback: p.Talkback}
	infos := make([]storage.CameraInfo, 0, len(p.Cameras))
	for _, c := range p.Cameras {
		path := rtspPath(c)
		infos = append(infos, storage.CameraInfo{DeviceID: c.ID, DeviceName: c.Name, Category: "sp",
			ProductID: c.ProductID, RTSPPath: path, UserKey: userKey})
		info.Cameras = append(info.Cameras, bridgeCam{ID: c.ID, Name: c.Name, Path: path,
			URL: fmt.Sprintf("rtsp://127.0.0.1:%d%s", port, path)})
	}
	if err := store.UpdateCamerasForUser(userKey, infos); err != nil {
		core.Logger.Warn().Msgf("Could not save cameras: %v", err)
	}

	srv := rtsp.NewRTSPServer(port, store)
	srv.BindAddress = "127.0.0.1" // the RTSP server has no authentication
	srv.MobileClient = client
	srv.Talkback = p.Talkback
	if err := srv.Start(); err != nil {
		return nil, fmt.Errorf("start RTSP server: %w", err)
	}
	server = srv
	core.Logger.Info().Msgf("Serving %d camera(s) on 127.0.0.1:%d (talkback: %v)", len(infos), port, p.Talkback)
	return info, nil
}

// rtspPath is the loopback path a camera is served on. It is built from the
// device id rather than the display name, which can collide, and uses only
// unreserved URL characters: the server matches the request's decoded path
// against it, so it must read the same encoded and decoded. Tuya ids are
// alphanumeric; anything else is hex-encoded.
func rtspPath(c Camera) string {
	if c.ID != "" && strings.Trim(c.ID, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") == "" {
		return "/" + c.ID
	}
	return "/cam-" + hex.EncodeToString([]byte(c.ID))
}
