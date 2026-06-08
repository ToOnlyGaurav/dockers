package com.vertx.common;

import java.util.List;
import java.util.Map;

/**
 * Capability for databases that support free-form query execution (SQL, etc.).
 */
public interface QueryCapable {

    /** Execute a query and return results as a list of row maps. */
    List<Map<String, Object>> executeQuery(String query) throws Exception;
}
