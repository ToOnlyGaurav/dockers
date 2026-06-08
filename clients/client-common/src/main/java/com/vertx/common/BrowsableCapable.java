package com.vertx.common;

import java.util.List;
import java.util.Map;

/**
 * Capability for databases that support listing/describing entities
 * (tables, sets, queues, znodes, etc.).
 */
public interface BrowsableCapable {

    /** List top-level entities (tables, sets, queues, child nodes). */
    List<String> listEntities(Map<String, String> params) throws Exception;

    /** Describe/inspect a specific entity. Returns metadata as key-value pairs. */
    Map<String, Object> describeEntity(String entity, Map<String, String> params) throws Exception;
}
