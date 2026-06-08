package com.vertx.common;

import java.util.List;

/**
 * Optional interface for clients to describe the parameters
 * required for each action. Used by ClientRegistry to build
 * metadata for the UI.
 */
public interface DescribableClient {

    /** Parameters for CRUD read action. */
    default List<DatabaseInfo.ParamInfo> readParams() { return List.of(); }

    /** Parameters for CRUD write action. */
    default List<DatabaseInfo.ParamInfo> writeParams() { return List.of(); }

    /** Parameters for CRUD delete action. */
    default List<DatabaseInfo.ParamInfo> deleteParams() { return List.of(); }

    /** Parameters for browse/list action. */
    default List<DatabaseInfo.ParamInfo> listParams() { return List.of(); }

    /** Parameters for publish action. */
    default List<DatabaseInfo.ParamInfo> publishParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("target", "Queue/Topic", "text", true, ""),
            new DatabaseInfo.ParamInfo("message", "Message", "textarea", true, "")
        );
    }

    /** Parameters for consume action. */
    default List<DatabaseInfo.ParamInfo> consumeParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("target", "Queue/Topic", "text", true, ""),
            new DatabaseInfo.ParamInfo("maxMessages", "Max Messages", "number", false, "1")
        );
    }
}
