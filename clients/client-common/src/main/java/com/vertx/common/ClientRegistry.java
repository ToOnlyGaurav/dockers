package com.vertx.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.*;
import java.util.function.Function;

/**
 * Central registry of all database clients. Provides:
 * - Discovery of available databases and their capabilities
 * - Generic action dispatch (the Dropwizard layer calls execute() without knowing the DB type)
 */
public class ClientRegistry {

    private static final Logger log = LoggerFactory.getLogger(ClientRegistry.class);

    private final Map<String, DatabaseClient> clients = new LinkedHashMap<>();

    public void register(DatabaseClient client) {
        clients.put(client.name(), client);
        log.info("Registered client: {}", client.name());
    }

    public DatabaseClient get(String name) {
        return clients.get(name);
    }

    public Collection<DatabaseClient> getAll() {
        return Collections.unmodifiableCollection(clients.values());
    }

    /**
     * Returns metadata for all registered databases, including health and capabilities.
     * Note: This does NOT establish connections - just returns configured databases.
     * Health checks happen only when you actually use a database.
     */
    public List<DatabaseInfo> listDatabases() {
        List<DatabaseInfo> result = new ArrayList<>();
        for (DatabaseClient client : clients.values()) {
            // Don't validate on list - just return as "not connected"
            // Connection will happen when user selects the database
            result.add(new DatabaseInfo(
                    client.name(), false, "Not connected (click to connect)",
                    getCapabilities(client),
                    getActionParams(client)
            ));
        }
        return result;
    }

    /**
     * Returns metadata for a single database WITH health check.
     * This will attempt to connect to verify the status.
     */
    public DatabaseInfo describeDatabase(String name) {
        DatabaseClient client = clients.get(name);
        if (client == null) return null;
        
        boolean healthy = false;
        String statusMessage = "Unknown";
        try {
            statusMessage = client.validate();
            healthy = true;
        } catch (Exception e) {
            statusMessage = "Connection failed: " + e.getMessage();
            log.warn("Failed to validate {}: {}", name, e.getMessage());
        }
        
        return new DatabaseInfo(
                client.name(), healthy, statusMessage,
                getCapabilities(client),
                getActionParams(client)
        );
    }

    /**
     * Generic action dispatch. The Dropwizard resource calls this single method.
     */
    @SuppressWarnings("unchecked")
    public Object execute(String dbName, String action, Map<String, Object> payload) throws Exception {
        DatabaseClient client = clients.get(dbName);
        if (client == null) {
            throw new IllegalArgumentException("Unknown database: " + dbName);
        }

        Map<String, String> params = extractParams(payload);
        Map<String, Object> value = payload.containsKey("value") ? (Map<String, Object>) payload.get("value") : null;

        return switch (action) {
            case "read" -> {
                if (!(client instanceof CrudCapable c)) throw unsupported(dbName, action);
                yield c.read(params);
            }
            case "write" -> {
                if (!(client instanceof CrudCapable c)) throw unsupported(dbName, action);
                c.write(params, value != null ? value : Collections.emptyMap());
                yield Map.of("status", "ok");
            }
            case "delete" -> {
                if (!(client instanceof CrudCapable c)) throw unsupported(dbName, action);
                c.delete(params);
                yield Map.of("status", "ok");
            }
            case "list" -> {
                if (!(client instanceof BrowsableCapable b)) throw unsupported(dbName, action);
                yield b.listEntities(params);
            }
            case "describe" -> {
                if (!(client instanceof BrowsableCapable b)) throw unsupported(dbName, action);
                String entity = (String) payload.getOrDefault("entity", "");
                yield b.describeEntity(entity, params);
            }
            case "query" -> {
                if (!(client instanceof QueryCapable q)) throw unsupported(dbName, action);
                String queryStr = (String) payload.get("query");
                if (queryStr == null || queryStr.isBlank()) throw new IllegalArgumentException("'query' is required");
                yield q.executeQuery(queryStr);
            }
            case "publish" -> {
                if (!(client instanceof PublishConsumeCapable p)) throw unsupported(dbName, action);
                String target = (String) payload.getOrDefault("target", "");
                String message = (String) payload.getOrDefault("message", "");
                p.publish(target, message);
                yield Map.of("status", "ok");
            }
            case "consume" -> {
                if (!(client instanceof PublishConsumeCapable p)) throw unsupported(dbName, action);
                String target = (String) payload.getOrDefault("target", "");
                int max = payload.containsKey("maxMessages") ? ((Number) payload.get("maxMessages")).intValue() : 1;
                yield p.consume(target, max);
            }
            case "validate" -> {
                yield Map.of("status", client.validate());
            }
            case "browse" -> {
                // Special browse action - use reflection to call browse method if available
                try {
                    java.lang.reflect.Method browseMethod = client.getClass().getMethod("browse", Map.class);
                    yield browseMethod.invoke(client, params);
                } catch (NoSuchMethodException e) {
                    throw new IllegalArgumentException("Browse action not supported for: " + dbName);
                } catch (Exception e) {
                    throw new RuntimeException("Error executing browse: " + e.getMessage(), e);
                }
            }
            case "scanSet" -> {
                // Aerospike scan set action
                try {
                    java.lang.reflect.Method scanMethod = client.getClass().getMethod("scanSet", Map.class);
                    yield scanMethod.invoke(client, params);
                } catch (NoSuchMethodException e) {
                    throw new IllegalArgumentException("scanSet action not supported for: " + dbName);
                } catch (Exception e) {
                    throw new RuntimeException("Error executing scanSet: " + e.getMessage(), e);
                }
            }
            case "getByKey" -> {
                // Aerospike get by key action
                try {
                    java.lang.reflect.Method getMethod = client.getClass().getMethod("getByKey", Map.class);
                    yield getMethod.invoke(client, params);
                } catch (NoSuchMethodException e) {
                    throw new IllegalArgumentException("getByKey action not supported for: " + dbName);
                } catch (Exception e) {
                    throw new RuntimeException("Error executing getByKey: " + e.getMessage(), e);
                }
            }
            default -> throw new IllegalArgumentException("Unknown action: " + action);
        };
    }

    public void closeAll() {
        for (DatabaseClient client : clients.values()) {
            try { client.close(); } catch (Exception e) { /* ignore */ }
        }
    }

    // --- private helpers ---

    private static List<String> getCapabilities(DatabaseClient client) {
        List<String> caps = new ArrayList<>();
        if (client instanceof CrudCapable) caps.add("crud");
        if (client instanceof BrowsableCapable) caps.add("browse");
        if (client instanceof QueryCapable) caps.add("query");
        if (client instanceof PublishConsumeCapable) caps.add("pubsub");
        return caps;
    }

    private static Map<String, List<DatabaseInfo.ParamInfo>> getActionParams(DatabaseClient client) {
        Map<String, List<DatabaseInfo.ParamInfo>> params = new LinkedHashMap<>();
        if (client instanceof CrudCapable) {
            params.put("read", client instanceof DescribableClient d ? d.readParams() : Collections.emptyList());
            params.put("write", client instanceof DescribableClient d ? d.writeParams() : Collections.emptyList());
            params.put("delete", client instanceof DescribableClient d ? d.deleteParams() : Collections.emptyList());
        }
        if (client instanceof BrowsableCapable) {
            params.put("list", client instanceof DescribableClient d ? d.listParams() : Collections.emptyList());
        }
        if (client instanceof QueryCapable) {
            params.put("query", List.of(new DatabaseInfo.ParamInfo("query", "SQL Query", "textarea", true, "")));
        }
        if (client instanceof PublishConsumeCapable) {
            params.put("publish", client instanceof DescribableClient d ? d.publishParams() :
                    List.of(new DatabaseInfo.ParamInfo("target", "Queue/Topic", "text", true, ""),
                            new DatabaseInfo.ParamInfo("message", "Message", "textarea", true, "")));
            params.put("consume", client instanceof DescribableClient d ? d.consumeParams() :
                    List.of(new DatabaseInfo.ParamInfo("target", "Queue/Topic", "text", true, ""),
                            new DatabaseInfo.ParamInfo("maxMessages", "Max Messages", "number", false, "1")));
        }
        return params;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, String> extractParams(Map<String, Object> payload) {
        Object p = payload.get("params");
        if (p instanceof Map) {
            Map<String, String> result = new LinkedHashMap<>();
            ((Map<String, Object>) p).forEach((k, v) -> result.put(k, String.valueOf(v)));
            return result;
        }
        return Collections.emptyMap();
    }

    private static IllegalArgumentException unsupported(String db, String action) {
        return new IllegalArgumentException("Database '" + db + "' does not support action '" + action + "'");
    }
}
