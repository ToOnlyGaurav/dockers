#!/usr/bin/env python3
"""
RabbitMQ Test Script - Read and Write
Usage:
  python rmq_test.py write   -> publish N messages to a queue
  python rmq_test.py read    -> consume messages from the queue
  python rmq_test.py both    -> publish then consume (default)

Requirements:
  pip install pika
"""

import sys
import time
import pika

# ── Configuration ─────────────────────────────────────────────────────────────
RMQ_HOST      = "localhost"
RMQ_PORT      = 5672
RMQ_VHOST     = "/"
RMQ_USER      = "guest"
RMQ_PASSWORD  = "guest"
QUEUE_NAME    = "test_queue"
NUM_MESSAGES  = 5
# ──────────────────────────────────────────────────────────────────────────────


def get_connection() -> pika.BlockingConnection:
    credentials = pika.PlainCredentials(RMQ_USER, RMQ_PASSWORD)
    params = pika.ConnectionParameters(
        host=RMQ_HOST,
        port=RMQ_PORT,
        virtual_host=RMQ_VHOST,
        credentials=credentials,
        heartbeat=60,
        connection_attempts=3,
        retry_delay=2,
    )
    return pika.BlockingConnection(params)


def declare_queue(channel: pika.adapters.blocking_connection.BlockingChannel):
    channel.queue_declare(queue=QUEUE_NAME, durable=True)


# ── WRITE ──────────────────────────────────────────────────────────────────────
def write_messages(n: int = NUM_MESSAGES):
    print(f"\n{'='*50}")
    print(f"[WRITE] Connecting to RabbitMQ at {RMQ_HOST}:{RMQ_PORT} ...")
    connection = get_connection()
    channel = connection.channel()
    declare_queue(channel)

    for i in range(1, n + 1):
        body = f"Hello from test script! Message #{i} at {time.strftime('%Y-%m-%d %H:%M:%S')}"
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE_NAME,
            body=body,
            properties=pika.BasicProperties(
                delivery_mode=2,  # persistent
                content_type="text/plain",
            ),
        )
        print(f"  [→] Sent: {body}")

    connection.close()
    print(f"[WRITE] Done. {n} message(s) published to queue '{QUEUE_NAME}'.")


# ── READ ───────────────────────────────────────────────────────────────────────
def read_messages(max_messages: int = NUM_MESSAGES):
    print(f"\n{'='*50}")
    print(f"[READ] Connecting to RabbitMQ at {RMQ_HOST}:{RMQ_PORT} ...")
    connection = get_connection()
    channel = connection.channel()
    declare_queue(channel)

    received = 0

    def callback(ch, method, properties, body):
        nonlocal received
        received += 1
        print(f"  [←] Received [{received}]: {body.decode()}")
        ch.basic_ack(delivery_tag=method.delivery_tag)
        if received >= max_messages:
            ch.stop_consuming()

    # Check how many messages are in the queue first
    q = channel.queue_declare(queue=QUEUE_NAME, durable=True, passive=True)
    available = q.method.message_count
    print(f"[READ] Messages available in queue '{QUEUE_NAME}': {available}")

    if available == 0:
        print("[READ] Queue is empty. Nothing to consume.")
        connection.close()
        return

    channel.basic_qos(prefetch_count=1)
    channel.basic_consume(queue=QUEUE_NAME, on_message_callback=callback)
    print(f"[READ] Waiting for up to {max_messages} message(s) ...")
    channel.start_consuming()

    connection.close()
    print(f"[READ] Done. {received} message(s) consumed from queue '{QUEUE_NAME}'.")


# ── MAIN ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    mode = sys.argv[1].lower() if len(sys.argv) > 1 else "both"

    if mode == "write":
        write_messages()
    elif mode == "read":
        read_messages()
    elif mode == "both":
        write_messages()
        time.sleep(1)
        read_messages()
    else:
        print(f"Unknown mode '{mode}'. Use: write | read | both")
        sys.exit(1)

