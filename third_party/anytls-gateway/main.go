// SPDX-License-Identifier: GPL-3.0-or-later
//
// anytls-socks-gateway: AnyTLS inbound listeners, each forwarding TCP to one fixed SOCKS5 upstream
// Copyright (C) 2026 csjcsl
//
// This program links github.com/sagernet/sing and github.com/sagernet/sing-anytls
// (GPL-3.0-or-later, Copyright (C) 2022 nekohasekai) and is distributed under the same terms.
// It has no routing, no DNS, no UDP, no logging to files and no management interface.

package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
	anytls "github.com/sagernet/sing-anytls"
)

var version = "dev"

type config struct {
	TLS       tlsConfig        `json:"tls"`
	Listeners []listenerConfig `json:"listeners"`
}

type tlsConfig struct {
	CertFile string `json:"cert_file"`
	KeyFile  string `json:"key_file"`
}

type listenerConfig struct {
	Listen   string       `json:"listen"`
	Password string       `json:"password"`
	SOCKS5   socksConfig  `json:"socks5"`
}

type socksConfig struct {
	Server   string `json:"server"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type handler struct{ upstream *socks.Client }

func (h handler) NewConnectionEx(ctx context.Context, inbound net.Conn, _ M.Socksaddr, destination M.Socksaddr, _ N.CloseHandlerFunc) {
	go func() {
		defer inbound.Close()
		ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		outbound, err := h.upstream.DialContext(ctx, N.NetworkTCP, destination)
		cancel()
		if err != nil {
			return
		}
		defer outbound.Close()
		done := make(chan struct{})
		go func() { _, _ = io.CopyBuffer(outbound, inbound, make([]byte, 16*1024)); close(done) }()
		_, _ = io.CopyBuffer(inbound, outbound, make([]byte, 16*1024))
		_ = inbound.Close()
		<-done
	}()
}

func loadConfig(path string) (config, error) {
	f, err := os.Open(path)
	if err != nil { return config{}, err }
	defer f.Close()
	var c config
	d := json.NewDecoder(f)
	d.DisallowUnknownFields()
	if err = d.Decode(&c); err != nil { return c, err }
	if len(c.Listeners) < 1 || c.TLS.CertFile == "" || c.TLS.KeyFile == "" { return c, errors.New("need TLS files and at least one listener") }
	seen := make(map[string]bool, len(c.Listeners))
	for _, l := range c.Listeners {
		if l.Listen == "" || l.Password == "" || l.SOCKS5.Server == "" || l.SOCKS5.Username == "" || l.SOCKS5.Password == "" { return c, errors.New("incomplete listener or SOCKS5 configuration") }
		if _, p, err := net.SplitHostPort(l.Listen); err != nil || p == "" { return c, errors.New("invalid listener address") }
		if _, p, err := net.SplitHostPort(l.SOCKS5.Server); err != nil || p == "" { return c, errors.New("invalid SOCKS5 server address") }
		if seen[l.Listen] { return c, errors.New("duplicate listener") }
		seen[l.Listen] = true
	}
	return c, nil
}

func runListener(ctx context.Context, c listenerConfig, tlsConf *tls.Config, wg *sync.WaitGroup) error {
	upstream := socks.NewClient(&N.DefaultDialer{}, M.ParseSocksaddr(c.SOCKS5.Server), socks.Version5, c.SOCKS5.Username, c.SOCKS5.Password)
	service, err := anytls.NewService(c.Password, anytls.ServiceOptions{Handler: handler{upstream: upstream}})
	if err != nil { return err }
	ln, err := net.Listen("tcp", c.Listen)
	if err != nil { return err }
	log.Printf("listening on %s; fixed SOCKS5 upstream %s", c.Listen, c.SOCKS5.Server)
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer ln.Close()
		go func() { <-ctx.Done(); _ = ln.Close() }()
		for {
			conn, err := ln.Accept()
			if err != nil {
				if ctx.Err() != nil || errors.Is(err, net.ErrClosed) { return }
				log.Printf("accept %s: %v", c.Listen, err)
				continue
			}
			go func(raw net.Conn) {
				defer raw.Close()
				_ = raw.SetDeadline(time.Now().Add(15 * time.Second))
				secure := tls.Server(raw, tlsConf)
				if err := secure.HandshakeContext(ctx); err != nil { return }
				_ = secure.SetDeadline(time.Time{})
				_ = service.NewConnection(ctx, secure, M.SocksaddrFromNet(raw.RemoteAddr()).Unwrap(), nil)
			}(conn)
		}
	}()
	return nil
}

func main() {
	path := flag.String("config", "/etc/anytls-socks-gateway/config.json", "configuration path")
	showVersion := flag.Bool("version", false, "print version and exit")
	check := flag.Bool("check", false, "validate the configuration and the TLS files, then exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("anytls-socks-gateway " + version)
		return
	}
	c, err := loadConfig(*path)
	if err != nil { log.Fatal(err) }
	cert, err := tls.LoadX509KeyPair(c.TLS.CertFile, c.TLS.KeyFile)
	if err != nil { log.Fatal(err) }
	if *check {
		fmt.Println("ok")
		return
	}
	tlsConf := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	var wg sync.WaitGroup
	for _, listener := range c.Listeners {
		if err := runListener(ctx, listener, tlsConf, &wg); err != nil { stop(); wg.Wait(); log.Fatal(err) }
	}
	<-ctx.Done()
	wg.Wait()
	fmt.Fprintln(os.Stderr, "stopped")
}
