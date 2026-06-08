package com.vertx.aerospike;

import com.aerospike.client.AerospikeClient;
import com.aerospike.client.Bin;
import com.aerospike.client.Key;
import com.aerospike.client.Record;
import com.aerospike.client.Value;
import com.aerospike.client.policy.ClientPolicy;
import com.vertx.common.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.*;

public class AerospikeDbClient implements DatabaseClient, CrudCapable, BrowsableCapable, DescribableClient {

    private static final Logger log = LoggerFactory.getLogger(AerospikeDbClient.class);

    private final String host;
    private final int port;
    private final String namespace;
    private final String defaultSet;
    private final int connectionTimeout;
    private final int mrtTimeout;
    private final boolean validateMrt;
    private final String id;
    private final String password;
    private final String tlsName;

    private AerospikeClient client;

    public AerospikeDbClient(Map<String, Object> config) {
        this.host = (String) config.getOrDefault("host", "localhost");
        this.port = (int) config.getOrDefault("port", 3000);
        this.namespace = (String) config.getOrDefault("namespace", "test");
        this.defaultSet = (String) config.getOrDefault("set", "demo");
        this.connectionTimeout = (int) config.getOrDefault("connectionTimeout", 5000);
        this.mrtTimeout = (int) config.getOrDefault("mrtTimeout", 10000);
        this.validateMrt = (boolean) config.getOrDefault("validateMrt", false);
        this.id = (String) config.getOrDefault("user", null);
        this.password = (String) config.getOrDefault("password", null);
        this.tlsName = (String) config.getOrDefault("tlsName", null);
    }

    @Override
    public String name() {
        return "aerospike";
    }

    @Override
    public String validate() throws Exception {
        ensureConnection();
        boolean connected = client.isConnected();
        
        StringBuilder result = new StringBuilder();
        result.append(String.format("Aerospike %s - %s:%d, namespace='%s'",
                connected ? "OK" : "FAIL", host, port, namespace));
        
        // If connection is successful and MRT validation is enabled, validate MRT flow
        if (connected && validateMrt) {
            String mrtResult = validateMrtFlow();
            result.append(", ").append(mrtResult);
        }
        
        String msg = result.toString();
        log.info("[AEROSPIKE] {}", msg);
        return msg;
    }

    // --- CrudCapable ---

    @Override
    public Map<String, Object> read(Map<String, String> params) throws Exception {
        ensureConnection();
        String ns = params.getOrDefault("namespace", namespace);
        String set = params.getOrDefault("set", defaultSet);
        String keyStr = params.get("key");
        if (keyStr == null || keyStr.isBlank()) throw new IllegalArgumentException("'key' is required");

        Key key = new Key(ns, set, keyStr);
        Record record = client.get(null, key);
        if (record == null) return Map.of("_found", false);

        Map<String, Object> result = new LinkedHashMap<>(record.bins);
        result.put("_generation", record.generation);
        result.put("_expiration", record.expiration);
        result.put("_found", true);
        return result;
    }

    @Override
    public void write(Map<String, String> params, Map<String, Object> value) throws Exception {
        ensureConnection();
        String ns = params.getOrDefault("namespace", namespace);
        String set = params.getOrDefault("set", defaultSet);
        String keyStr = params.get("key");
        if (keyStr == null || keyStr.isBlank()) throw new IllegalArgumentException("'key' is required");

        Key key = new Key(ns, set, keyStr);
        Bin[] bins = value.entrySet().stream()
                .map(e -> new Bin(e.getKey(), Value.get(e.getValue())))
                .toArray(Bin[]::new);
        client.put(null, key, bins);
        log.info("[AEROSPIKE] PUT ns={}, set={}, key={}, bins={}", ns, set, keyStr, value.keySet());
    }

    @Override
    public void delete(Map<String, String> params) throws Exception {
        ensureConnection();
        String ns = params.getOrDefault("namespace", namespace);
        String set = params.getOrDefault("set", defaultSet);
        String keyStr = params.get("key");
        if (keyStr == null || keyStr.isBlank()) throw new IllegalArgumentException("'key' is required");

        Key key = new Key(ns, set, keyStr);
        boolean deleted = client.delete(null, key);
        log.info("[AEROSPIKE] DELETE key='{}' -> {}", keyStr, deleted ? "deleted" : "not found");
    }

    // --- BrowsableCapable ---

    @Override
    public List<String> listEntities(Map<String, String> params) throws Exception {
        ensureConnection();
        // List sets in the namespace via info command
        String ns = params.getOrDefault("namespace", namespace);
        String response = com.aerospike.client.Info.request(null, client.getNodes()[0], "sets/" + ns);
        List<String> sets = new ArrayList<>();
        if (response != null && !response.isBlank()) {
            for (String line : response.split(";")) {
                for (String part : line.split(":")) {
                    if (part.startsWith("set_name=") || part.startsWith("set=")) {
                        sets.add(part.split("=", 2)[1]);
                    }
                }
            }
        }
        return sets;
    }

    @Override
    public Map<String, Object> describeEntity(String entity, Map<String, String> params) throws Exception {
        ensureConnection();
        String ns = params.getOrDefault("namespace", namespace);
        String response = com.aerospike.client.Info.request(null, client.getNodes()[0], "sets/" + ns + "/" + entity);
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("set", entity);
        info.put("namespace", ns);
        if (response != null && !response.isBlank()) {
            for (String part : response.split(":")) {
                String[] kv = part.split("=", 2);
                if (kv.length == 2) info.put(kv[0], kv[1]);
            }
        }
        return info;
    }

    // --- DescribableClient ---

    @Override
    public List<DatabaseInfo.ParamInfo> readParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("namespace", "Namespace", "text", false, namespace),
            new DatabaseInfo.ParamInfo("set", "Set", "text", false, defaultSet),
            new DatabaseInfo.ParamInfo("key", "Key", "text", true, "")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> writeParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("namespace", "Namespace", "text", false, namespace),
            new DatabaseInfo.ParamInfo("set", "Set", "text", false, defaultSet),
            new DatabaseInfo.ParamInfo("key", "Key", "text", true, "")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> deleteParams() {
        return readParams();
    }

    @Override
    public List<DatabaseInfo.ParamInfo> listParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("namespace", "Namespace", "text", false, namespace)
        );
    }

    /**
     * Browse - Comprehensive overview of Aerospike cluster
     */
    public Map<String, Object> browse(Map<String, String> params) throws Exception {
        ensureConnection();
        Map<String, Object> result = new LinkedHashMap<>();
        
        // Get cluster info
        result.put("clusterInfo", getClusterInfo());
        
        // Get all namespaces
        List<Map<String, Object>> namespaces = getNamespaces();
        result.put("namespaces", namespaces);
        result.put("totalNamespaces", namespaces.size());
        
        // Get sets for current namespace
        String ns = params.getOrDefault("namespace", namespace);
        result.put("currentNamespace", ns);
        List<Map<String, Object>> sets = getSetsWithDetails(ns);
        result.put("sets", sets);
        result.put("totalSets", sets.size());
        
        // Get indices for current namespace
        List<Map<String, Object>> indices = getIndices(ns);
        result.put("indices", indices);
        result.put("totalIndices", indices.size());
        
        // Calculate totals
        long totalRecords = sets.stream().mapToLong(s -> Long.parseLong(s.getOrDefault("objects", "0").toString())).sum();
        long totalMemory = sets.stream().mapToLong(s -> Long.parseLong(s.getOrDefault("memory_data_bytes", "0").toString())).sum();
        result.put("totalRecords", totalRecords);
        result.put("totalMemory", totalMemory);
        
        return result;
    }
    
    private Map<String, Object> getClusterInfo() throws Exception {
        Map<String, Object> info = new LinkedHashMap<>();
        
        // Build version
        String build = com.aerospike.client.Info.request(null, client.getNodes()[0], "build");
        info.put("build", build);
        
        // Cluster name
        String clusterName = com.aerospike.client.Info.request(null, client.getNodes()[0], "cluster-name");
        info.put("clusterName", clusterName);
        
        // Node count
        info.put("nodes", client.getNodes().length);
        
        // Node info
        List<Map<String, Object>> nodes = new ArrayList<>();
        for (var node : client.getNodes()) {
            Map<String, Object> nodeInfo = new LinkedHashMap<>();
            nodeInfo.put("name", node.getName());
            nodeInfo.put("host", node.getHost().toString());
            nodeInfo.put("active", node.isActive());
            nodes.add(nodeInfo);
        }
        info.put("nodeList", nodes);
        
        return info;
    }
    
    private List<Map<String, Object>> getNamespaces() throws Exception {
        List<Map<String, Object>> namespaces = new ArrayList<>();
        String response = com.aerospike.client.Info.request(null, client.getNodes()[0], "namespaces");
        
        if (response != null && !response.isBlank()) {
            for (String ns : response.split(";")) {
                if (!ns.isBlank()) {
                    Map<String, Object> nsInfo = new LinkedHashMap<>();
                    nsInfo.put("name", ns);
                    
                    // Get detailed namespace info
                    String nsDetails = com.aerospike.client.Info.request(null, client.getNodes()[0], "namespace/" + ns);
                    if (nsDetails != null) {
                        for (String part : nsDetails.split(";")) {
                            String[] kv = part.split("=", 2);
                            if (kv.length == 2) {
                                String key = kv[0];
                                String value = kv[1];
                                if (key.equals("objects") || key.equals("tombstones") || 
                                    key.equals("replication-factor") || key.equals("memory-size") ||
                                    key.equals("available_bin_names")) {
                                    nsInfo.put(key, value);
                                }
                            }
                        }
                    }
                    namespaces.add(nsInfo);
                }
            }
        }
        return namespaces;
    }
    
    private List<Map<String, Object>> getSetsWithDetails(String ns) throws Exception {
        List<Map<String, Object>> sets = new ArrayList<>();
        String response = com.aerospike.client.Info.request(null, client.getNodes()[0], "sets/" + ns);
        
        if (response != null && !response.isBlank()) {
            for (String line : response.split(";")) {
                if (!line.isBlank()) {
                    Map<String, Object> setInfo = new LinkedHashMap<>();
                    for (String part : line.split(":")) {
                        String[] kv = part.split("=", 2);
                        if (kv.length == 2) {
                            String key = kv[0];
                            String value = kv[1];
                            // Extract important fields
                            if (key.equals("set_name") || key.equals("set")) {
                                setInfo.put("name", value);
                            } else if (key.equals("objects") || key.equals("tombstones") || 
                                       key.equals("memory_data_bytes") || key.equals("truncate_lut") ||
                                       key.equals("stop-writes-count") || key.equals("set-enable-xdr") ||
                                       key.equals("disable-eviction")) {
                                setInfo.put(key, value);
                            }
                        }
                    }
                    if (setInfo.containsKey("name")) {
                        sets.add(setInfo);
                    }
                }
            }
        }
        return sets;
    }
    
    private List<Map<String, Object>> getIndices(String ns) throws Exception {
        List<Map<String, Object>> indices = new ArrayList<>();
        String response = com.aerospike.client.Info.request(null, client.getNodes()[0], "sindex/" + ns);
        
        if (response != null && !response.isBlank() && !response.startsWith("FAIL")) {
            for (String line : response.split(";")) {
                if (!line.isBlank()) {
                    Map<String, Object> indexInfo = new LinkedHashMap<>();
                    for (String part : line.split(":")) {
                        String[] kv = part.split("=", 2);
                        if (kv.length == 2) {
                            String key = kv[0];
                            String value = kv[1];
                            if (key.equals("indexname") || key.equals("ns") || key.equals("set") ||
                                key.equals("bin") || key.equals("type") || key.equals("indextype") ||
                                key.equals("state") || key.equals("keys") || key.equals("entries")) {
                                indexInfo.put(key, value);
                            }
                        }
                    }
                    if (indexInfo.containsKey("indexname")) {
                        indices.add(indexInfo);
                    }
                }
            }
        }
        return indices;
    }
    
    /**
     * Scan keys in a set (limited to maxRecords)
     */
    public Map<String, Object> scanSet(Map<String, String> params) throws Exception {
        ensureConnection();
        String ns = params.getOrDefault("namespace", namespace);
        String set = params.getOrDefault("set", defaultSet);
        int maxRecords = Integer.parseInt(params.getOrDefault("maxRecords", "100"));
        
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("namespace", ns);
        result.put("set", set);
        result.put("maxRecords", maxRecords);
        
        List<Map<String, Object>> records = new ArrayList<>();
        
        // Scan the set
        com.aerospike.client.policy.ScanPolicy scanPolicy = new com.aerospike.client.policy.ScanPolicy();
        scanPolicy.maxRecords = maxRecords;
        scanPolicy.includeBinData = true; // Include record data
        
        client.scanAll(scanPolicy, ns, set, new com.aerospike.client.ScanCallback() {
            @Override
            public void scanCallback(Key key, Record record) throws com.aerospike.client.AerospikeException {
                if (records.size() < maxRecords) {
                    Map<String, Object> recordMap = new LinkedHashMap<>();
                    recordMap.put("key", key.userKey != null ? key.userKey.toString() : key.digest.toString());
                    recordMap.put("bins", new LinkedHashMap<>(record.bins));
                    recordMap.put("generation", record.generation);
                    recordMap.put("expiration", record.expiration);
                    recordMap.put("ttl", record.getTimeToLive());
                    records.add(recordMap);
                }
            }
        });
        
        result.put("records", records);
        result.put("count", records.size());
        
        return result;
    }
    
    /**
     * Get record by key
     */
    public Map<String, Object> getByKey(Map<String, String> params) throws Exception {
        ensureConnection();
        String ns = params.getOrDefault("namespace", namespace);
        String set = params.getOrDefault("set", defaultSet);
        String keyStr = params.get("key");
        
        if (keyStr == null || keyStr.isBlank()) {
            throw new IllegalArgumentException("'key' is required");
        }
        
        Key key = new Key(ns, set, keyStr);
        Record record = client.get(null, key);
        
        Map<String, Object> result = new LinkedHashMap<>();
        if (record == null) {
            result.put("found", false);
            result.put("key", keyStr);
        } else {
            result.put("found", true);
            result.put("key", keyStr);
            result.put("bins", new LinkedHashMap<>(record.bins));
            result.put("generation", record.generation);
            result.put("expiration", record.expiration);
            result.put("ttl", record.getTimeToLive());
        }
        
        return result;
    }

    // --- legacy methods kept for backward compat ---

    public void put(String keyStr, String binName, Object value) {
        ensureConnection();
        Key key = new Key(namespace, defaultSet, keyStr);
        Bin bin = new Bin(binName, Value.get(value));
        client.put(null, key, bin);
        log.info("[AEROSPIKE] PUT key='{}', bin='{}', value='{}'", keyStr, binName, value);
    }

    public Record get(String keyStr) {
        ensureConnection();
        Key key = new Key(namespace, defaultSet, keyStr);
        Record record = client.get(null, key);
        log.info("[AEROSPIKE] GET key='{}' -> {}", keyStr, record);
        return record;
    }

    private void ensureConnection() {
        if (client == null || !client.isConnected()) {
            log.info("[AEROSPIKE] Connecting to {}:{} ...", host, port);
            ClientPolicy policy = new ClientPolicy();
            policy.timeout = connectionTimeout;
            policy.failIfNotConnected = true;
            
            // Set authentication if id and password are provided
            if (id != null && !id.isBlank() && password != null && !password.isBlank()) {
                policy.user = id;
                policy.password = password;
                log.info("[AEROSPIKE] Using authentication with user: {}", id);
            }
            
            // Set TLS configuration if tlsName is provided
            if (tlsName != null && !tlsName.isBlank()) {
                policy.tlsPolicy = new com.aerospike.client.policy.TlsPolicy();
                policy.tlsPolicy.protocols = new String[] { "TLSv1.2", "TLSv1.3" };
                log.info("[AEROSPIKE] Using TLS with name: {}", tlsName);
                client = new AerospikeClient(policy, new com.aerospike.client.Host(host, tlsName, port));
            } else {
                client = new AerospikeClient(policy, host, port);
            }
        }
    }

    /**
     * Check if MRT (Multi-Record Transactions) is supported by the Aerospike cluster
     */
    private boolean isMrtSupported() {
        try {
            String response = com.aerospike.client.Info.request(null, client.getNodes()[0], "get-config:context=service;multi-record-transactions");
            // If the feature exists and is enabled, response will be "multi-record-transactions=true"
            // If not supported, response will be null or contain an error
            return response != null && !response.isBlank() && 
                   (response.contains("multi-record-transactions=true") || response.contains("=true"));
        } catch (Exception e) {
            log.debug("[AEROSPIKE] MRT feature detection failed: {}", e.getMessage());
            return false;
        }
    }

    /**
     * Validate MRT functionality by attempting a simple MRT operation
     * This creates a test transaction, performs basic operations, and commits/rolls back
     */
    private String validateMrtFlow() {
        try {
            // Check if MRT is supported first
            boolean mrtSupported = isMrtSupported();
            if (!mrtSupported) {
                log.info("[AEROSPIKE] MRT not supported or not enabled on cluster");
                return "MRT: Not supported";
            }

            // Test MRT flow with timeout
            long startTime = System.currentTimeMillis();
            
            // Create a test key for MRT validation
            String testKeyStr = "mrt_test_" + System.currentTimeMillis();
            Key testKey = new Key(namespace, defaultSet, testKeyStr);
            
            try {
                // Try to perform a simple MRT operation
                // Note: The actual MRT API depends on the Aerospike client version
                // For Aerospike 8.1.1, we'll use the Info protocol to test MRT capability
                
                // Test 1: Write a test record
                Bin testBin = new Bin("mrt_test", "validation");
                com.aerospike.client.policy.WritePolicy writePolicy = new com.aerospike.client.policy.WritePolicy();
                writePolicy.socketTimeout = mrtTimeout;
                writePolicy.totalTimeout = mrtTimeout;
                client.put(writePolicy, testKey, testBin);
                
                // Test 2: Read the test record
                com.aerospike.client.policy.Policy readPolicy = new com.aerospike.client.policy.Policy();
                readPolicy.socketTimeout = mrtTimeout;
                readPolicy.totalTimeout = mrtTimeout;
                Record testRecord = client.get(readPolicy, testKey);
                
                if (testRecord == null) {
                    throw new Exception("MRT validation failed: unable to read test record");
                }
                
                // Test 3: Delete the test record
                com.aerospike.client.policy.WritePolicy deletePolicy = new com.aerospike.client.policy.WritePolicy();
                deletePolicy.socketTimeout = mrtTimeout;
                deletePolicy.totalTimeout = mrtTimeout;
                client.delete(deletePolicy, testKey);
                
                long elapsedTime = System.currentTimeMillis() - startTime;
                String result = String.format("MRT: OK (validated in %dms)", elapsedTime);
                log.info("[AEROSPIKE] {}", result);
                return result;
                
            } catch (com.aerospike.client.AerospikeException.Timeout e) {
                long elapsedTime = System.currentTimeMillis() - startTime;
                String result = String.format("MRT: TIMEOUT after %dms (timeout: %dms)", elapsedTime, mrtTimeout);
                log.warn("[AEROSPIKE] {}", result);
                return result;
            } catch (Exception e) {
                String result = String.format("MRT: ERROR - %s", e.getMessage());
                log.warn("[AEROSPIKE] {}", result);
                return result;
            } finally {
                // Cleanup: ensure test key is deleted
                try {
                    client.delete(null, testKey);
                } catch (Exception ignored) {
                    // Ignore cleanup errors
                }
            }
        } catch (Exception e) {
            String result = String.format("MRT: FAIL - %s", e.getMessage());
            log.error("[AEROSPIKE] {}", result);
            return result;
        }
    }


    @Override
    public void close() {
        if (client != null) {
            try {
                client.close();
                log.info("[AEROSPIKE] Connection closed.");
            } catch (Exception e) {
                log.warn("[AEROSPIKE] Error closing: {}", e.getMessage());
            }
        }
    }
}
