package main

import (
	"golang.org/x/term"

	"fmt"
	"log"
	"io"
	"os"
	"strings"
)

const sockPath = "/tmp/tai.sock"

func readLineRaw() (string, error) {
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return "", err
	}
	defer term.Restore(fd, oldState)

	var buf []byte
	b := make([]byte, 1)

	for {
		_, err := os.Stdin.Read(b)
		if err != nil {
			return "", err
		}
		ch := b[0]

		switch ch {
		case '\r', '\n':
			fmt.Print("\r\n")
			return string(buf), nil
		case 127, 8: // Backspace
			if len(buf) > 0 {
				buf = buf[:len(buf)-1]
				fmt.Print("\b \b")
			}
		default:
			if ch >= 32 && ch < 127 {
				buf = append(buf, ch)
				fmt.Printf("%c", ch)
			}
		}
	}
}

func pipelineMode(model string) {
	input, _ := io.ReadAll(os.Stdin)
	messages := []ChatMessage{
		{Role: "system", Content: "You are 'tai', a command-line AI assistant running on a shell pipeline."},
		{Role: "user", Content: string(input)},
	}
	resp, err := SendChat(messages)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	fmt.Println(resp)
}

func interactiveMode(model string) {
	log.Println("tai: interactive mode (type 'exit' to quit). Powered by Groq.")
	messages := []ChatMessage{
		{Role: "system", Content: "You are 'tai', a command-line AI assistant running in interactive mode."},
	}
	for {
		fmt.Print("> ")
		line, err := readLineRaw()
		if err != nil {
			break
		}
		line = strings.TrimSpace(line)
		if line == "exit" {
			break
		}
		messages = append(messages, ChatMessage{Role: "user", Content: line})
		resp, err := SendChat(messages)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			break
		}
		messages = append(messages, ChatMessage{Role: "assistant", Content: resp})
	}
}

func ideMode(model string) {
	err := InitProjectPrompt()
	if err != nil {
		fmt.Fprintln(os.Stderr, "init error:", err)
		os.Exit(1)
	}

	log.Println("Socket ready")
	taiSocket(sockPath)
}

// tai This is a go package that ... continue this comment
func main() {
	model := "llama3-70b-8192"

	if len(os.Args) > 1 && os.Args[1] == "-c" {
		ideMode(model)
		return
	}

	fi, _ := os.Stdin.Stat()
	if (fi.Mode() & os.ModeCharDevice) == 0 {
		pipelineMode(model)
	} else {
		interactiveMode(model)
	}
}

