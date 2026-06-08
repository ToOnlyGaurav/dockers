package com.vertx.rmq;

import com.rabbitmq.client.*;
import com.vertx.common.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.LocalDateTime;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public class RmqClient implements DatabaseClient, PublishConsumeCapable, BrowsableCapable, DescribableClient {

    private static final Logger log = LoggerFactory.getLogger(RmqClient.class);

    private final String host;
    private final int port;
    private final String virtualHost;
    private final String username;
    private final String password;
    private final String queue;
    private final String exchange;
    private final String routingKey;
    private final boolean durable;
    private final int messageCount;
    private final long consumerTimeoutMs;

    private Connection connection;

    public RmqClient(Map<String, Object> config) {
        this.host = (String) config.getOrDefault("host", "localhost");
        this.port = (int) config.getOrDefault("port", 5672);
        this.virtualHost = (String) config.getOrDefault("virtualHost", "/");
        this.username = (String) config.getOrDefault("username", "guest");
        this.password = (String) config.getOrDefault("password", "guest");
        this.queue = (String) config.getOrDefault("queue", "test_queue");
        this.exchange = (String) config.getOrDefault("exchange", "");
        this.routingKey = (String) config.getOrDefault("routingKey", "test_queue");
        this.durable = (boolean) config.getOrDefault("durable", true);
        this.messageCount = (int) config.getOrDefault("messageCount", 5);
        this.consumerTimeoutMs = ((Number) config.getOrDefault("consumerTimeoutMs", 5000)).longValue();
    }

    @Override
    public String name() {
        return "rmq";
    }

    @Override
    public String validate() throws Exception {
        ConnectionFactory factory = buildFactory();
        log.info("[RMQ] Validating connection to {}:{} ...", host, port);
        try (Connection conn = factory.newConnection();
             Channel channel = conn.createChannel()) {
            channel.queueDeclare(queue, durable, false, false, null);
            long msgCount = channel.messageCount(queue);
            String msg = String.format("RMQ OK - connected to %s:%d, queue '%s' has %d message(s)", host, port, queue, msgCount);
            log.info("[RMQ] {}", msg);
            return msg;
        }
    }

    // --- PublishConsumeCapable ---

    @Override
    public void publish(String target, String message) throws Exception {
        ensureConnection();
        String q = (target == null || target.isBlank()) ? queue : target;
        try (Channel channel = connection.createChannel()) {
            channel.queueDeclare(q, durable, false, false, null);
            channel.basicPublish(exchange, q,
                    durable ? MessageProperties.PERSISTENT_TEXT_PLAIN : null,
                    message.getBytes());
            log.info("[RMQ] Published to '{}': {}", q, message);
        }
    }

    @Override
    public List<String> consume(String target, int maxMessages) throws Exception {
        ensureConnection();
        String q = (target == null || target.isBlank()) ? queue : target;
        List<String> messages = Collections.synchronizedList(new ArrayList<>());
        try (Channel channel = connection.createChannel()) {
            channel.queueDeclare(q, durable, false, false, null);
            long available = channel.messageCount(q);
            if (available == 0) return messages;

            int toConsume = (int) Math.min(available, maxMessages);
            CountDownLatch latch = new CountDownLatch(toConsume);
            channel.basicQos(1);
            channel.basicConsume(q, false, (tag, delivery) -> {
                messages.add(new String(delivery.getBody()));
                channel.basicAck(delivery.getEnvelope().getDeliveryTag(), false);
                latch.countDown();
            }, consumerTag -> {});
            latch.await(consumerTimeoutMs, TimeUnit.MILLISECONDS);
        }
        return messages;
    }

    // --- BrowsableCapable ---

    @Override
    public List<String> listEntities(Map<String, String> params) throws Exception {
        // RabbitMQ Java client doesn't have a list-queues API easily.
        // Return the configured queue as a known entity.
        return List.of(queue);
    }

    @Override
    public Map<String, Object> describeEntity(String entity, Map<String, String> params) throws Exception {
        ensureConnection();
        String q = (entity == null || entity.isBlank()) ? queue : entity;
        try (Channel channel = connection.createChannel()) {
            AMQP.Queue.DeclareOk ok = channel.queueDeclarePassive(q);
            Map<String, Object> info = new LinkedHashMap<>();
            info.put("queue", q);
            info.put("messageCount", ok.getMessageCount());
            info.put("consumerCount", ok.getConsumerCount());
            return info;
        }
    }

    // --- DescribableClient ---

    @Override
    public List<DatabaseInfo.ParamInfo> publishParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("target", "Queue Name", "text", false, queue),
            new DatabaseInfo.ParamInfo("message", "Message Body", "textarea", true, "")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> consumeParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("target", "Queue Name", "text", false, queue),
            new DatabaseInfo.ParamInfo("maxMessages", "Max Messages", "number", false, "5")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> listParams() {
        return List.of();
    }

    // --- legacy methods kept for backward compat ---

    public void produce() throws Exception {
        ensureConnection();
        try (Channel channel = connection.createChannel()) {
            channel.queueDeclare(queue, durable, false, false, null);
            log.info("[RMQ-PRODUCER] Publishing {} message(s) to queue '{}'...", messageCount, queue);
            for (int i = 1; i <= messageCount; i++) {
                String body = String.format("Message #%d | sent at %s", i, LocalDateTime.now());
                channel.basicPublish(exchange, routingKey,
                        durable ? MessageProperties.PERSISTENT_TEXT_PLAIN : null,
                        body.getBytes());
                log.info("[RMQ-PRODUCER]  -> Sent: {}", body);
            }
            log.info("[RMQ-PRODUCER] Done. {} message(s) published.", messageCount);
        }
    }

    public void consume() throws Exception {
        ensureConnection();
        try (Channel channel = connection.createChannel()) {
            channel.queueDeclare(queue, durable, false, false, null);
            long msgCount = channel.messageCount(queue);
            log.info("[RMQ-CONSUMER] Messages available in queue '{}': {}", queue, msgCount);
            if (msgCount == 0) {
                log.warn("[RMQ-CONSUMER] Queue is empty. Nothing to consume.");
                return;
            }
            int toConsume = (int) Math.min(msgCount, messageCount);
            CountDownLatch latch = new CountDownLatch(toConsume);
            AtomicInteger received = new AtomicInteger(0);
            channel.basicQos(1);
            channel.basicConsume(queue, false, (tag, delivery) -> {
                String message = new String(delivery.getBody());
                int count = received.incrementAndGet();
                log.info("[RMQ-CONSUMER]  <- [{}] Received: {}", count, message);
                channel.basicAck(delivery.getEnvelope().getDeliveryTag(), false);
                latch.countDown();
            }, consumerTag -> log.warn("[RMQ-CONSUMER] Consumer cancelled: {}", consumerTag));

            boolean completed = latch.await(consumerTimeoutMs, TimeUnit.MILLISECONDS);
            if (!completed) {
                log.warn("[RMQ-CONSUMER] Timed out. Received {}/{}", received.get(), toConsume);
            } else {
                log.info("[RMQ-CONSUMER] Done. {} message(s) consumed.", received.get());
            }
        }
    }

    private void ensureConnection() throws Exception {
        if (connection == null || !connection.isOpen()) {
            log.info("[RMQ] Connecting to {}:{} ...", host, port);
            connection = buildFactory().newConnection();
        }
    }

    private ConnectionFactory buildFactory() {
        ConnectionFactory factory = new ConnectionFactory();
        factory.setHost(host);
        factory.setPort(port);
        factory.setVirtualHost(virtualHost);
        factory.setUsername(username);
        factory.setPassword(password);
        return factory;
    }

    @Override
    public void close() {
        if (connection != null && connection.isOpen()) {
            try {
                connection.close();
                log.info("[RMQ] Connection closed.");
            } catch (Exception e) {
                log.warn("[RMQ] Error closing connection: {}", e.getMessage());
            }
        }
    }
}
