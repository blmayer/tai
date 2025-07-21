package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
)

var (
	socketSend    = make(chan string)
	socketReceive = make(chan string)
)

func taiSocket(sockPath string) error {
	os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return fmt.Errorf("failed to start socket server: %w", err)
	}
	defer ln.Close()
	log.Printf("[tai] socket server listening at %s\n", sockPath)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println("accept error:", err)
			continue
		}
		log.Println("Got a client")
		go handleSocketConnection(conn)
	}
}

func handleSocketConnection(conn net.Conn) {
	for {
		buf := make([]byte, 2<<20)
		n, err := conn.Read(buf)
		if err == io.EOF {
			log.Println("client disconnected")
			break
		}
		if err != nil {
			log.Println("read error:", err)
			continue
		}
		log.Printf("[tai] read %s\n", buf)

		prompt := strings.TrimSpace(string(buf[:n]))
		if prompt == "" {
			continue
		}
		reply, err := processRequest(prompt)
		if err != nil {
			log.Println("process error:", err)
			continue
		}
		
		log.Printf("Sending reply %s\n", reply)
		_, err = conn.Write([]byte(reply))
		if err != nil {
			log.Println("write error:", err)
			continue
		}
	}
}

