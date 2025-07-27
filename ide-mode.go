package main

import (
	"bytes"
	"fmt"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"os"
	"path/filepath"
	"strings"
)

const cacheDir = ".tai-cache"

var (
	preamble string

	history = []ChatMessage{
		{
			Role: "system",
			Content: `### System
			You are Tai, a coding assistant for nvim that can return code changes, execute commands and give general code advice.
			Return **ONLY** valid multipart MIME message with named parts.

			### Intructions
			Do not include any extraneous data outside of the MIME message like a preamble, notes or backticks.
			The response must start with MIME-version and boundary headers, vary and do not use spaces or special characters for the boundary. 
			- Each MIME part MUST contain Content-Disposition: attachment; with the correct filename field.
			- Always use \r\n (CRLF) for line endings.
			- For user-facing text, use a plain/text part named 'text'. 
			- For code changes, include a text/x-diff in a part named 'patch'. 
			- If you need to execute commands, include them in a part named 'commands'. 
			- If your response involves multiple steps, include them in a part named 'plan'. 
			- Do not nest MIME messages.

			#### patch
			For the patch part return a valid patch text to be used by the patch program. Use correct locations based on
			the provided cursor position, or the file content if sent.
			If the location is needed and was not sent use a @read command to request the file content.
			If the location is not important also include the patch in a human friendly form in the "text" part.

			#### plan
			Do not send the "plan" part for plans with only 1 step. Use [ ] and [X] to keep track of the progress.

			#### commands
			Commands have 2 types: internal and external ones. Use them sparingly as they are very expensive.

			##### Internal
			They are intended to be handled by Tai, they **MUST** start with @.

			- @read <relative path to file>: use this if you need to know the file's contents.

			##### External
			They are run as normal commands on the shell, these can be any programs on a shell pipeline.
			Be very considerate to the user's current setup to not use programs the user lacks, or designed for other OSs.

			### Context
			Users basically want one of 2 things: code changes or general info.
			For code changes use the unified format so users can easily spot the differences, the text section can contain notes but be brief.
			General info is more informal but include important details and comparisons if requested, be concise.

			### Example output
			MIME-Version: 1.0
			Content-Type: multipart/mixed; boundary="asdfasdfasdf"

			--asdfasdfasdf
			Content-Type: text/plain; charset="utf-8"
			Content-Disposition: form-data; name="text"

			I'm considering you want a doc string.

			--asdfasdfasdf
			Content-Type: text/x-patch; charset="utf-8"
			Content-Disposition: form-data; name="patch"

			diff --git a/abc.py b/abc.py
			--- a/abc.py
			+++ b/abc.py
			@@ -0,0 +1,5 @@
			-# The function sendRequest ... complete this comment
			+# The function sendRequest is used to send a request
			+# Parameters:
			+# @method: str
			+# @url: str
			+# @body: str
			--asdfasdfasdf--
			`,
		},
	}
)

// InitProjectPrompt scans the current directory and returns a prompt
// describing the file structure.
func InitProjectPrompt() error {
	fmt.Println("[tai] Starting project")
	dir, err := os.Getwd()
	if err != nil {
		return err
	}

	preamble = fmt.Sprintf(
		"You are managing a project at %s, which contains the following files and structure:\n",
		dir,
	)

	files := 0
	err = filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() && len(path) > 1 && strings.HasPrefix(path, ".") {
			return filepath.SkipDir
		}
		if !info.IsDir() {
			preamble += fmt.Sprintf("- %s\n", path)
			files++
		}
		return nil
	})
	if err != nil {
		return err
	}

	if files > 10 {
		log.Println("[tai] Too many files to summarise, skipping.")
		return nil
	}
	summary, err := getFilesSummary()
	if err != nil {
		return err
	}

	if summary != "" {
		preamble += "\nHere are summaries of the files:\n\n" + summary
	}

	return nil
}

// SummarizeFiles sends each file's contents to Groq and asks for a short summary.
// It caches the summaries in .tai-cache/filename.summary.txt
func getFilesSummary() (string, error) {
	log.Println("[tai] Creating file caches")
	os.MkdirAll(cacheDir, 0o755)
	summaries := ""

	err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		log.Printf("[tai] Checking file %s\n", path)
		if err != nil {
			log.Printf("[tai] walk error: %s\n", err)
			return err
		}
		if info.IsDir() && len(path) > 1 && path[0] == '.' {
			log.Println("[tai] Skiping dir")
			return filepath.SkipDir
		}
		if !info.Mode().IsRegular() {
			log.Println("[tai] File is not regular")
			return nil
		}

		summaryPath := filepath.Join(cacheDir, path+".summary.txt")
		needsUpdate := true

		if stat, err := os.Stat(summaryPath); err == nil {
			if srcStat, err := os.Stat(path); err == nil && srcStat.ModTime().Before(stat.ModTime()) {
				needsUpdate = false
			}
		}

		var summary string
		if needsUpdate {
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			defer file.Close()

			code, err := io.ReadAll(file)
			if err != nil {
				return err
			}

			msg := []ChatMessage{
				{Role: "system", Content: "You are a code analysis assistant."},
				{Role: "user", Content: fmt.Sprintf("Summarize the following file. Be very brief, but include defined functions, classes, and variables.\n\nFile: %s\n\n```\n%s\n```", path, code)},
			}

			reply, err := SendChat(msg)
			if err != nil {
				return fmt.Errorf("[tai] error summarizing %s: %w", path, err)
			}

			os.WriteFile(summaryPath, []byte(reply), 0o644)
			summary = reply
			log.Printf("[tai] Updated %s\n", path)
		} else {
			file, err := os.Open(summaryPath)
			if err != nil {
				return err
			}
			defer file.Close()

			cached, err := io.ReadAll(file)
			if err != nil {
				return err
			}
			summary = string(cached)
			log.Printf("Using cache for %s\n", path)
		}

		summaries += fmt.Sprintf("[tai] Summary for %s:\n%s\n\n", path, summary)
		return nil
	})

	return summaries, err
}

type Response struct {
	Text     string
	Plan     string
	Patch    string
	Commands []string
}

func parseMIMEString(raw string) (Response, error) {
	result := Response{}

	// Split headers and body
	headerEnd := strings.Index(raw, "\n\n")
	if headerEnd == -1 {
		headerEnd = strings.Index(raw, "\r\n\r\n")
	}
	if headerEnd == -1 {
		return result, fmt.Errorf("[tai] invalid MIME message: no header/body split")
	}

	headerText := raw[:headerEnd]
	bodyText := raw[headerEnd+2:] // skip \n\n or \r\n\r\n

	// Parse Content-Type to get the boundary
	var contentType string
	for _, line := range strings.Split(headerText, "\n") {
		if strings.HasPrefix(strings.ToLower(line), "content-type:") {
			contentType = strings.TrimSpace(strings.SplitN(line, ":", 2)[1])
			break
		}
	}
	if contentType == "" {
		return result, fmt.Errorf("[tai] no Content-Type header found")
	}

	mediaType, params, err := mime.ParseMediaType(contentType)
	if err != nil || !strings.HasPrefix(mediaType, "multipart/") {
		return result, fmt.Errorf("invalid Content-Type: %v", contentType)
	}

	// Create a multipart reader from the body
	reader := multipart.NewReader(bytes.NewBufferString(bodyText), params["boundary"])
	for {
		part, err := reader.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			return result, err
		}

		name := part.FileName()
		if name == "" {
			cd := part.Header.Get("Content-Disposition")
			if _, params, err := mime.ParseMediaType(cd); err == nil {
				name = params["name"]
			}
		}

		data, err := io.ReadAll(part)
		if err != nil {
			return result, err
		}

		switch name {
		case "text":
			result.Text = string(data)
		case "plan":
			result.Plan = string(data)
		case "patch":
			result.Patch = string(data)
		case "commands":
			cmds := strings.Split(string(data), "\n")
			result.Commands = cmds
		}
	}

	return result, nil
}

func processRequest(prompt string) (string, error) {
	log.Printf("[tai] Received prompt %s\n", prompt)

	messages := append(history, ChatMessage{Role: "user", Content: prompt})

	reply, err := SendChat(messages)
	if err != nil {
		log.Println("[tai] SendChat error:", err)
		return "", err
	}

	log.Println("[tai] got response:", reply)
	history = append(history, ChatMessage{Role: "assistant", Content: reply})
	return reply, nil
}
