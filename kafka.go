package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/segmentio/kafka-go"
)

const (
	pobRequestsTopic = "pob-requests"
	pobResultsTopic  = "pob-results"
)

// pobKafkaRequest is consumed from the pob-requests topic.
// Character holds the raw GGGCharacter JSON that is forwarded verbatim to the
// PoB Lua worker (identical to the HTTP request body).
type pobKafkaRequest struct {
	CharacterID string          `json:"character_id"`
	Game        string          `json:"game"`
	Character   json.RawMessage `json:"character"`
}

// pobKafkaResult is published to the pob-results topic.
// Character echoes the original request payload so the backend can reconstruct
// the CharacterPob entity without an extra DB lookup.
type pobKafkaResult struct {
	CharacterID string `json:"character_id"`
	Export      string `json:"export"`
	Error       string `json:"error,omitempty"`
}

// runKafkaConsumer reads character data from the pob-requests topic, processes
// each request through the shared PoB worker pool, and publishes the resulting
// export strings to the pob-results topic.
func runKafkaConsumer(ctx context.Context, p *pool, broker string) {
	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers:        []string{broker},
		Topic:          pobRequestsTopic,
		GroupID:        "pob-server",
		MaxBytes:       10 << 20, // 10 MB
		CommitInterval: time.Second,
	})
	defer reader.Close()

	writer := &kafka.Writer{
		Addr:                   kafka.TCP(broker),
		Topic:                  pobResultsTopic,
		Balancer:               &kafka.LeastBytes{},
		AllowAutoTopicCreation: true,
	}
	defer writer.Close()

	log.Printf("kafka consumer started on broker %s, topic %s", broker, pobRequestsTopic)

	for {
		msg, err := reader.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("kafka fetch error: %v", err)
			time.Sleep(time.Second)
			continue
		}

		// Process synchronously to honour the pool's concurrency limits.
		result := processKafkaRequest(ctx, p, msg.Value)
		publishKafkaResult(ctx, writer, result)
		reader.CommitMessages(ctx, msg)
	}
}

func processKafkaRequest(ctx context.Context, p *pool, data []byte) pobKafkaResult {
	var req pobKafkaRequest
	if err := json.Unmarshal(data, &req); err != nil {
		return pobKafkaResult{Error: fmt.Sprintf("failed to unmarshal request: %v", err)}
	}

	var f *flavor
	for _, fl := range p.flavors {
		if fl.name == req.Game {
			f = fl
			break
		}
	}
	if f == nil {
		return pobKafkaResult{
			CharacterID: req.CharacterID,
			Error:       fmt.Sprintf("unknown game %q", req.Game),
		}
	}

	export, err := p.processJob(ctx, f, "import-character", []byte(req.Character))
	if err != nil {
		return pobKafkaResult{
			CharacterID: req.CharacterID,
			Error:       err.Error(),
		}
	}

	return pobKafkaResult{
		CharacterID: req.CharacterID,
		Export:      string(export),
	}
}

func publishKafkaResult(ctx context.Context, writer *kafka.Writer, result pobKafkaResult) {
	resultJSON, err := json.Marshal(result)
	if err != nil {
		log.Printf("kafka: failed to marshal result for character %s: %v", result.CharacterID, err)
		return
	}
	writeCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := writer.WriteMessages(writeCtx, kafka.Message{
		Key:   []byte(result.CharacterID),
		Value: resultJSON,
	}); err != nil && ctx.Err() == nil {
		log.Printf("kafka: failed to publish result for character %s: %v", result.CharacterID, err)
	}
}
