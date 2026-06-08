package com.vertx.common;

import java.util.List;
import java.util.Map;

/**
 * Capability for message-oriented systems (RabbitMQ, Kafka, etc.).
 */
public interface PublishConsumeCapable {

    /** Publish a message to a target (queue/topic). */
    void publish(String target, String message) throws Exception;

    /** Consume message(s) from a target. Returns list of messages. */
    List<String> consume(String target, int maxMessages) throws Exception;
}
