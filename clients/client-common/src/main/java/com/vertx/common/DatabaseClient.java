package com.vertx.common;

/**
 * Common interface for all database clients.
 * Connections are lazy - nothing connects until validate() or an operation is called.
 */
public interface DatabaseClient extends AutoCloseable {

    /** Unique name for this client (e.g. "rmq", "aerospike", "mariadb"). */
    String name();

    /**
     * Validates connectivity to the database.
     * This is where the connection is first established (lazy).
     * Returns a human-readable status message.
     */
    String validate() throws Exception;

    /** Closes the connection if open. */
    @Override
    void close();
}
