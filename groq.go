package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

const groqAPIBase = "https://api.groq.com/openai/v1"
const model = "meta-llama/llama-4-scout-17b-16e-instruct"

var (
	groqKey    string
	httpClient *http.Client
)

func init() {
	groqKey = os.Getenv("GROQ_API_KEY")
	if groqKey == "" {
		fmt.Fprintln(os.Stderr, "❌ Missing GROQ_API_KEY environment variable.")
		os.Exit(1)
	}

	httpClient = &http.Client{Timeout: 15 * time.Second}
}

type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type ChatRequest struct {
	Model    string        `json:"model"`
	Messages []ChatMessage `json:"messages"`
}

type ChatResponse struct {
	Choices []struct {
		Message ChatMessage `json:"message"`
	} `json:"choices"`
}

func SendChat(messages []ChatMessage) (string, error) {
	reqBody := ChatRequest{
		Model:    model,
		Messages: messages,
	}
	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequest("POST", groqAPIBase+"/chat/completions", bytes.NewBuffer(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+groqKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("Groq API error: %s", string(respBody))
	}

	var chatResp ChatResponse
	if err := json.Unmarshal(respBody, &chatResp); err != nil {
		return "", fmt.Errorf("JSON decode error: %v\nRaw: %s", err, string(respBody))
	}

	if len(chatResp.Choices) == 0 {
		return "", fmt.Errorf("No response from Groq")
	}

	return chatResp.Choices[0].Message.Content, nil
}

