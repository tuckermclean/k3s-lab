package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/apimachinery/pkg/api/resource"
)

// Web-shell server: creates per-user ephemeral pods (sleep infinity) and bridges a websocket to /bin/bash via kube exec.

var upgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

type Server struct {
	cfg        *rest.Config
	client     *kubernetes.Clientset
	sessionNS  string
	image      string
	shellCmd   []string
	idleTO     time.Duration
	maxTO      time.Duration
	cleanupTO  time.Duration
	cpuReq     string
	memReq     string
	cpuLim     string
	memLim     string
}

func getEnv(key, def string) string { if v := os.Getenv(key); v != "" { return v }; return def }

func newServer() (*Server, error) {
	cfg, err := rest.InClusterConfig()
	if err != nil { return nil, fmt.Errorf("in-cluster config: %w", err) }
	cli, err := kubernetes.NewForConfig(cfg)
	if err != nil { return nil, fmt.Errorf("client: %w", err) }
	idle, _ := strconv.Atoi(getEnv("IDLE_TIMEOUT_SECONDS", "600"))
	maxs, _ := strconv.Atoi(getEnv("MAX_SESSION_SECONDS", "1800"))
	clean, _ := strconv.Atoi(getEnv("CLEANUP_GRACE_SECONDS", "5"))
	return &Server{
		cfg:       cfg,
		client:    cli,
		sessionNS: getEnv("SESSION_NAMESPACE", "web-shell-sessions"),
		image:     getEnv("SHELL_IMAGE", "debian:bookworm-slim"),
		shellCmd:  []string{"/bin/bash", "-l"},
		idleTO:    time.Duration(idle) * time.Second,
		maxTO:     time.Duration(maxs) * time.Second,
		cleanupTO: time.Duration(clean) * time.Second,
		cpuReq:    getEnv("CPU_REQUEST", "50m"),
		memReq:    getEnv("MEM_REQUEST", "64Mi"),
		cpuLim:    getEnv("CPU_LIMIT", "200m"),
		memLim:    getEnv("MEM_LIMIT", "256Mi"),
	}, nil
}

func (s *Server) userFromHeaders(r *http.Request) (string, error) {
	user := r.Header.Get("X-authentik-username")
	if user == "" { user = r.Header.Get("X-User") }
	if user == "" { return "", fmt.Errorf("unauthorized: missing identity header") }
	return safe(user), nil
}

func safe(v string) string { return strings.ToLower(strings.Map(func(r rune) rune { if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' { return r }; return '-' }, v)) }

func randID() string { b := make([]byte, 5); _, _ = rand.Read(b); return hex.EncodeToString(b) }

func (s *Server) podNameFor(user string) string { return fmt.Sprintf("shell-%s-%s", safe(user), randID()) }

func (s *Server) existingPod(ctx context.Context, user string) (string, error) {
	ls := labels.Set{"app": "web-shell", "user": user}.AsSelector().String()
	pl, err := s.client.CoreV1().Pods(s.sessionNS).List(ctx, metav1.ListOptions{LabelSelector: ls})
	if err != nil { return "", err }
	for _, p := range pl.Items {
		if p.Status.Phase == corev1.PodRunning {
			return p.Name, nil
		}
	}
	return "", nil
}

func (s *Server) createPod(ctx context.Context, user string) (string, error) {
	name := s.podNameFor(user)
	p := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: s.sessionNS,
			Labels:    map[string]string{"app": "web-shell", "user": user},
		},
		Spec: corev1.PodSpec{
			SecurityContext: &corev1.PodSecurityContext{ RunAsNonRoot: ptr(true), RunAsUser: ptr32(1000), FSGroup: ptr32(1000) },
			Containers: []corev1.Container{{
				Name:            "shell",
				Image:           s.image,
				ImagePullPolicy: corev1.PullIfNotPresent,
				Command:         []string{"/bin/sh", "-lc", "sleep infinity"},
				Stdin:           true,
				StdinOnce:       false,
				TTY:             true,
				Resources:       resources(s.cpuReq, s.memReq, s.cpuLim, s.memLim),
				SecurityContext: &corev1.SecurityContext{ RunAsNonRoot: ptr(true), AllowPrivilegeEscalation: ptr(false) },
			}},
			RestartPolicy: corev1.RestartPolicyNever,
		},
	}
	_, err := s.client.CoreV1().Pods(s.sessionNS).Create(ctx, p, metav1.CreateOptions{})
	if err != nil { return "", err }
	return name, nil
}

func resources(cpuReq, memReq, cpuLim, memLim string) corev1.ResourceRequirements {
	rr := corev1.ResourceRequirements{Requests: corev1.ResourceList{}, Limits: corev1.ResourceList{}}
	if q, err := resource.ParseQuantity(cpuReq); err == nil { rr.Requests[corev1.ResourceCPU] = q }
	if q, err := resource.ParseQuantity(memReq); err == nil { rr.Requests[corev1.ResourceMemory] = q }
	if q, err := resource.ParseQuantity(cpuLim); err == nil { rr.Limits[corev1.ResourceCPU] = q }
	if q, err := resource.ParseQuantity(memLim); err == nil { rr.Limits[corev1.ResourceMemory] = q }
	return rr
}

func ptr(b bool) *bool { return &b }
func ptr32(i int32) *int32 { return &i }

func (s *Server) waitReady(ctx context.Context, name string) error {
	return wait.PollUntilContextTimeout(ctx, 500*time.Millisecond, 60*time.Second, true, func(ctx context.Context) (done bool, err error) {
		p, err := s.client.CoreV1().Pods(s.sessionNS).Get(ctx, name, metav1.GetOptions{})
		if err != nil { return false, nil }
		if p.Status.Phase != corev1.PodRunning { return false, nil }
		for _, c := range p.Status.ContainerStatuses { if c.Ready { return true, nil } }
		return false, nil
	})
}

func (s *Server) deletePod(ctx context.Context, name string) { _ = s.client.CoreV1().Pods(s.sessionNS).Delete(ctx, name, metav1.DeleteOptions{}) }

func (s *Server) handleStart(w http.ResponseWriter, r *http.Request) {
	user, err := s.userFromHeaders(r)
	if err != nil { http.Error(w, err.Error(), http.StatusUnauthorized); return }
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second); defer cancel()
	name, err := s.existingPod(ctx, user)
	if err != nil { http.Error(w, err.Error(), 500); return }
	if name == "" {
		name, err = s.createPod(ctx, user)
		if err != nil { http.Error(w, fmt.Sprintf("create pod: %v", err), 500); return }
	}
	if err := s.waitReady(ctx, name); err != nil { http.Error(w, fmt.Sprintf("pod not ready: %v", err), 500); return }
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"pod": name})
}

type msg struct { Type string `json:"type"`; Data string `json:"data"`; Cols int `json:"cols"`; Rows int `json:"rows"` }

type sizeQueue struct{ ch chan remotecommand.TerminalSize }
func (q *sizeQueue) Next() *remotecommand.TerminalSize { sz, ok := <-q.ch; if !ok { return nil }; return &sz }

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	user, err := s.userFromHeaders(r)
	if err != nil { http.Error(w, err.Error(), http.StatusUnauthorized); return }
	pod := r.URL.Query().Get("pod")
	if pod == "" { http.Error(w, "missing pod", 400); return }
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil { return }
	defer c.Close()

	stdinR, stdinW := io.Pipe()
	last := time.Now()
	idleTO := s.idleTO
	maxTO := s.maxTO
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// Idle timeout goroutine
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		expire := time.NewTimer(maxTO)
		for {
			select {
			case <-ctx.Done(): return
			case <-expire.C:
				c.WriteMessage(websocket.TextMessage, []byte("\r\n[session max duration reached]\r\n"))
				c.Close()
				return
			case <-t.C:
				if time.Since(last) > idleTO { c.WriteMessage(websocket.TextMessage, []byte("\r\n[idle timeout]\r\n")); c.Close(); return }
			}
		}
	}()

	q := &sizeQueue{ch: make(chan remotecommand.TerminalSize, 1)}
	go func() {
		for {
			_, raw, err := c.ReadMessage()
			if err != nil { stdinW.Close(); cancel(); return }
			last = time.Now()
			var m msg
			if json.Unmarshal(raw, &m) == nil {
				switch m.Type {
				case "input": stdinW.Write([]byte(m.Data))
				case "resize": q.ch <- remotecommand.TerminalSize{Width: uint16(m.Cols), Height: uint16(m.Rows)}
				}
			}
		}
	}()

	go func() { <-ctx.Done(); time.Sleep(s.cleanupTO); s.deletePod(context.Background(), pod) }()

	req := s.client.CoreV1().RESTClient().Post().Resource("pods").Namespace(s.sessionNS).Name(pod).SubResource("exec")
	req.Param("container", "shell").Param("stdin", "true").Param("stdout", "true").Param("stderr", "true").Param("tty", "true")
	for _, c := range s.shellCmd { req.Param("command", c) }
	exec, err := remotecommand.NewSPDYExecutor(s.cfg, http.MethodPost, req.URL())
	if err != nil { c.WriteMessage(websocket.TextMessage, []byte("exec error: "+err.Error())); return }
	writer := &wsWriter{c: c}
	err = exec.Stream(remotecommand.StreamOptions{Stdin: stdinR, Stdout: writer, Stderr: writer, Tty: true, TerminalSizeQueue: q})
	if err != nil { c.WriteMessage(websocket.TextMessage, []byte("stream ended: "+err.Error())) }
}

type wsWriter struct{ c *websocket.Conn }
func (w *wsWriter) Write(p []byte) (int, error) {
	b, _ := json.Marshal(msg{Type: "output", Data: string(p)})
	return len(p), w.c.WriteMessage(websocket.TextMessage, b)
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" { http.NotFound(w, r); return }
	http.ServeFile(w, r, "/app/static/index.html")
}

func main() {
	s, err := newServer()
	if err != nil { log.Fatalf("init: %v", err) }
	http.HandleFunc("/", s.handleIndex)
	http.HandleFunc("/api/start", s.handleStart)
	http.HandleFunc("/ws", s.handleWS)
	port := getEnv("PORT", "8080")
	log.Printf("web-shell server listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
