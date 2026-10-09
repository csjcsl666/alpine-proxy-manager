// SPDX-License-Identifier: GPL-3.0-or-later
//
// agw-probe: AnyTLS 业务探测工具, 只用于验收测试
// 读取网关的 config.json (凭据只在进程内使用, 绝不输出), 对每个 listener 建立 AnyTLS 连接,
// 经它向目标发一个 HTTP GET, 输出 成功或失败 与响应体首行 (用来回显出口 IP)
// 用法: agw-probe -config config.json -target host:port -path /
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	anytls "github.com/sagernet/sing-anytls"
)

type listener struct {
	Listen   string `json:"listen"`
	Password string `json:"password"`
}

type config struct {
	Listeners []listener `json:"listeners"`
}

func probe(l listener, target, path string) (string, error) {
	_, port, err := net.SplitHostPort(l.Listen)
	if err != nil {
		return "", err
	}
	dial := func(ctx context.Context) (net.Conn, error) {
		var d net.Dialer
		raw, err := d.DialContext(ctx, "tcp", "127.0.0.1:"+port)
		if err != nil {
			return nil, err
		}
		c := tls.Client(raw, &tls.Config{InsecureSkipVerify: true, ServerName: "gw.apm.test"})
		if err := c.HandshakeContext(ctx); err != nil {
			raw.Close()
			return nil, err
		}
		return c, nil
	}
	client, err := anytls.NewClient(anytls.ClientOptions{Password: l.Password, DialOut: dial, IdleSessionCheckInterval: time.Second, IdleSessionTimeout: 5 * time.Second})
	if err != nil {
		return port, err
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	conn, err := client.DialContext(ctx, M.ParseSocksaddr(target))
	if err != nil {
		return port, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
	host := target
	if h, _, e := net.SplitHostPort(target); e == nil {
		host = h
	}
	if _, err = fmt.Fprintf(conn, "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: agw-probe\r\n\r\n", path, host); err != nil {
		return port, err
	}
	r := bufio.NewReader(conn)
	status, err := r.ReadString('\n')
	if err != nil {
		return port, fmt.Errorf("no response: %v", err)
	}
	if !strings.Contains(status, " 200 ") {
		return port, fmt.Errorf("http status %q", strings.TrimSpace(status))
	}
	body := ""
	for {
		line, e := r.ReadString('\n')
		if strings.TrimSpace(line) == "" && (e != nil || body == "") {
			if e != nil {
				break
			}
			// 头部结束后读第一行正文
			b, _ := r.ReadString('\n')
			body = strings.TrimSpace(b)
			break
		}
		if e != nil {
			break
		}
	}
	return port, fmt.Errorf("OK:%s", body)
}

func main() {
	path := flag.String("config", "", "gateway config.json")
	target := flag.String("target", "api.ipify.org:80", "target host:port (plain HTTP)")
	urlPath := flag.String("path", "/", "HTTP path")
	flag.Parse()
	f, err := os.Open(*path)
	if err != nil {
		fmt.Println("FAIL config", err)
		os.Exit(2)
	}
	var c config
	if err = json.NewDecoder(f).Decode(&c); err != nil {
		fmt.Println("FAIL config parse")
		os.Exit(2)
	}
	bad := 0
	for _, l := range c.Listeners {
		port, err := probe(l, *target, *urlPath)
		if err != nil && strings.HasPrefix(err.Error(), "OK:") {
			fmt.Printf("OK listener=%s exit=%s\n", port, strings.TrimPrefix(err.Error(), "OK:"))
			continue
		}
		bad++
		// 错误信息可能含目标地址, 不含凭据
		fmt.Printf("FAIL listener=%s reason=%v\n", port, err)
	}
	if bad > 0 {
		os.Exit(1)
	}
}
