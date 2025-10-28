package main

import (
	"golang.org/x/term"

	"fmt"
	"io"
	"log"
	"os"
	"strings"
)

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

func pipelineMode(prompt string) {
	input, _ := io.ReadAll(os.Stdin)
	messages := []ChatMessage{
		{Role: "system", Content: `### System
			You are 'tai', a command-line AI assistant running on a shell pipeline.

			### Instructions
			You are part of a UNIX style pipeline, so the user will give you the output from other commands such as ls, cat, grep etc; and your output will probably be used for other commands or the terminal. So:
			- Format your responses in a line oriented way or whatever the user instructs you.
			- You can use ANSI escapes and other terminal formating sequences for prettier output.
			- Be concise and tune your output so other programs can easily read your output.
			- Output **ONLY** what was requested for you, do not add comments or metadata.

			### Input Format
			You will receive the input in two optional parts:
			1. The user prompt with instructions and
			2. The standard input from the pipeline.

			#### Example
			Prompt:
			Return a funny name for each file name

			Input:
			file1.txt
			avatar.png
			notes.md

			Your example output:
			garbage.txt
			my-ugly-photo.png
			things-i-keep-forgeting.md
			`},
		{Role: "user", Content: fmt.Sprintf("Prompt:\n%s\n\nInput:\n%s", prompt, string(input))},
	}
	resp, err := SendChat(messages)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	fmt.Println(resp)
}

func interactiveMode() {
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
		fmt.Println(resp)
		messages = append(messages, ChatMessage{Role: "assistant", Content: resp})
	}
}

// tai This is a go package that ... continue this comment
func main() {
	prompt := ""
	if len(os.Args) > 1 {
		prompt = strings.Join(os.Args[1:], " ")
	}

	fi, _ := os.Stdin.Stat()
	if (fi.Mode() & os.ModeCharDevice) == 0 || prompt != "" {
		pipelineMode(prompt)
	} else {
		interactiveMode()
	}
}
