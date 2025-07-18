package main

import (
	"fmt"
	"log"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const cacheDir = ".tai-cache"

var (
	prompt string

	history = []ChatMessage{}
)

// InitProjectPrompt scans the current directory and returns a prompt
// describing the file structure.
func InitProjectPrompt() error {
	fmt.Println("Starting project")

	prompt = "The project contains the following files and structure:\n"
	err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() && len(path) > 1 && strings.HasPrefix(path, ".") {
			return filepath.SkipDir
		}
		if !info.IsDir() {
			prompt += fmt.Sprintf("- %s\n", path)
		}
		return nil
	})
	if err != nil {
		return err
	}

	summary, err := getFilesSummary()
	if err != nil {
		return err
	}

	if summary != "" {
		prompt += "\nHere are summaries of the files:\n\n" + summary
	}

	return nil
}

// SummarizeFiles sends each file's contents to Groq and asks for a short summary.
// It caches the summaries in .tai-cache/filename.summary.txt
func getFilesSummary() (string, error) {
	log.Println("Creating file caches")
	os.MkdirAll(cacheDir, 0755)
	var summaries = ""

	err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		log.Printf("Checking file %s\n", path)
		if err != nil {
			log.Printf("walk error: %s\n", err)
			return err
		}
		if info.IsDir() && len(path) > 1 && path[0] == '.' {
			log.Println("Skiping dir")
			return filepath.SkipDir
		}
		if !info.Mode().IsRegular() {
			log.Println("File is not regular")
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
				return fmt.Errorf("error summarizing %s: %w", path, err)
			}

			os.WriteFile(summaryPath, []byte(reply), 0644)
			summary = reply
			log.Printf("Updated %s\n", path)
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

		summaries += fmt.Sprintf("Summary for %s:\n%s\n\n", path, summary)
		return nil
	})

	return summaries, err
} 

func process(message string) (string, error) {
	log.Printf("Received message %s\n", message)

	messages := []ChatMessage{
		{Role: "system", Content: prompt},
		{Role: "system", Content: "Your answear must me a valid MIME message. Dont include anything outside the MIME message."},
		{Role: "user", Content: message},
	}

	reply, err := SendChat(messages)
	if err != nil {
		log.Println("SendChat error:", err)
		return "", err
	}

	log.Println("[tai] got response:", reply)
	return reply, nil
}
