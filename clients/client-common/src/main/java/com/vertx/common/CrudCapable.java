package com.vertx.common;

import java.util.Map;

/**
 * Capability for databases that support key-value CRUD operations.
 * params map contains the addressing keys (e.g. namespace, set, key for Aerospike;
 * table, rowkey for HBase; path for ZooKeeper).
 */
public interface CrudCapable {

    /** Read a record. Returns the value as a map of field->value. */
    Map<String, Object> read(Map<String, String> params) throws Exception;

    /** Write/upsert a record. */
    void write(Map<String, String> params, Map<String, Object> value) throws Exception;

    /** Delete a record. */
    void delete(Map<String, String> params) throws Exception;
}
