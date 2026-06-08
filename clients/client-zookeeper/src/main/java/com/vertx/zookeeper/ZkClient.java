package com.vertx.zookeeper;

import com.vertx.common.*;
import org.apache.zookeeper.CreateMode;
import org.apache.zookeeper.ZooDefs;
import org.apache.zookeeper.ZooKeeper;
import org.apache.zookeeper.data.Stat;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class ZkClient implements DatabaseClient, CrudCapable, BrowsableCapable, DescribableClient {

    private static final Logger log = LoggerFactory.getLogger(ZkClient.class);

    private final String connectString;
    private final int sessionTimeoutMs;

    private ZooKeeper zooKeeper;

    public ZkClient(Map<String, Object> config) {
        this.connectString = (String) config.getOrDefault("connectString", "localhost:2181");
        this.sessionTimeoutMs = (int) config.getOrDefault("sessionTimeoutMs", 5000);
    }

    @Override
    public String name() {
        return "zk";
    }

    @Override
    public String validate() throws Exception {
        ensureConnection();
        List<String> children = zooKeeper.getChildren("/", false);
        String msg = String.format("ZooKeeper OK - connected to %s, root has %d children: %s",
                connectString, children.size(), children);
        log.info("[ZK] {}", msg);
        return msg;
    }

    // --- CrudCapable ---

    @Override
    public Map<String, Object> read(Map<String, String> params) throws Exception {
        ensureConnection();
        String path = params.getOrDefault("path", "/");
        Stat stat = zooKeeper.exists(path, false);
        if (stat == null) return Map.of("_found", false, "path", path);

        byte[] data = zooKeeper.getData(path, false, stat);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("_found", true);
        result.put("path", path);
        result.put("data", data != null ? new String(data, StandardCharsets.UTF_8) : "");
        result.put("version", stat.getVersion());
        result.put("dataLength", stat.getDataLength());
        result.put("numChildren", stat.getNumChildren());
        result.put("ctime", stat.getCtime());
        result.put("mtime", stat.getMtime());
        return result;
    }

    @Override
    public void write(Map<String, String> params, Map<String, Object> value) throws Exception {
        ensureConnection();
        String path = params.getOrDefault("path", "/");
        String data = (String) value.getOrDefault("data", "");
        byte[] bytes = data.getBytes(StandardCharsets.UTF_8);

        Stat stat = zooKeeper.exists(path, false);
        if (stat == null) {
            // Create the node (including parent paths if needed)
            zooKeeper.create(path, bytes, ZooDefs.Ids.OPEN_ACL_UNSAFE, CreateMode.PERSISTENT);
            log.info("[ZK] CREATED path={}", path);
        } else {
            zooKeeper.setData(path, bytes, stat.getVersion());
            log.info("[ZK] UPDATED path={}, version={}", path, stat.getVersion());
        }
    }

    @Override
    public void delete(Map<String, String> params) throws Exception {
        ensureConnection();
        String path = params.getOrDefault("path", "/");
        if ("/".equals(path)) throw new IllegalArgumentException("Cannot delete root node");
        Stat stat = zooKeeper.exists(path, false);
        if (stat != null) {
            zooKeeper.delete(path, stat.getVersion());
            log.info("[ZK] DELETED path={}", path);
        }
    }

    // --- BrowsableCapable ---

    @Override
    public List<String> listEntities(Map<String, String> params) throws Exception {
        ensureConnection();
        String path = params.getOrDefault("path", "/");
        return zooKeeper.getChildren(path, false);
    }

    @Override
    public Map<String, Object> describeEntity(String entity, Map<String, String> params) throws Exception {
        String parentPath = params.getOrDefault("path", "/");
        String fullPath = "/".equals(parentPath) ? "/" + entity : parentPath + "/" + entity;
        return read(Map.of("path", fullPath));
    }
    
    /**
     * Browse znodes with detailed grid information
     */
    public Map<String, Object> browse(Map<String, String> params) throws Exception {
        ensureConnection();
        String path = params.getOrDefault("path", "/");
        
        // Get current node info
        Stat currentStat = zooKeeper.exists(path, false);
        if (currentStat == null) {
            throw new IllegalArgumentException("Path does not exist: " + path);
        }
        
        byte[] currentData = zooKeeper.getData(path, false, currentStat);
        List<String> children = zooKeeper.getChildren(path, false);
        
        // Build result
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("currentPath", path);
        result.put("currentData", currentData != null ? new String(currentData, StandardCharsets.UTF_8) : "");
        result.put("currentStat", buildStatMap(currentStat));
        
        // Parent path
        String parentPath = path.equals("/") ? null : path.substring(0, Math.max(path.lastIndexOf('/'), 1));
        if (parentPath != null && parentPath.isEmpty()) parentPath = "/";
        result.put("parentPath", parentPath);
        
        // Build children list with metadata
        List<Map<String, Object>> childrenDetails = new ArrayList<>();
        for (String child : children) {
            String childPath = path.equals("/") ? "/" + child : path + "/" + child;
            try {
                Stat childStat = zooKeeper.exists(childPath, false);
                if (childStat != null) {
                    byte[] childData = zooKeeper.getData(childPath, false, childStat);
                    Map<String, Object> childInfo = new LinkedHashMap<>();
                    childInfo.put("name", child);
                    childInfo.put("path", childPath);
                    childInfo.put("dataLength", childStat.getDataLength());
                    childInfo.put("numChildren", childStat.getNumChildren());
                    childInfo.put("version", childStat.getVersion());
                    childInfo.put("ctime", childStat.getCtime());
                    childInfo.put("mtime", childStat.getMtime());
                    childInfo.put("ephemeral", childStat.getEphemeralOwner() != 0);
                    childInfo.put("dataPreview", childData != null && childData.length > 0 
                        ? new String(childData, StandardCharsets.UTF_8).substring(0, Math.min(50, childData.length))
                        : "");
                    childrenDetails.add(childInfo);
                }
            } catch (Exception e) {
                log.warn("[ZK] Failed to get details for child {}: {}", childPath, e.getMessage());
            }
        }
        result.put("children", childrenDetails);
        
        return result;
    }
    
    private Map<String, Object> buildStatMap(Stat stat) {
        Map<String, Object> statMap = new LinkedHashMap<>();
        statMap.put("version", stat.getVersion());
        statMap.put("cversion", stat.getCversion());
        statMap.put("aversion", stat.getAversion());
        statMap.put("dataLength", stat.getDataLength());
        statMap.put("numChildren", stat.getNumChildren());
        statMap.put("ctime", stat.getCtime());
        statMap.put("mtime", stat.getMtime());
        statMap.put("ephemeralOwner", stat.getEphemeralOwner());
        statMap.put("ephemeral", stat.getEphemeralOwner() != 0);
        return statMap;
    }

    // --- DescribableClient ---

    @Override
    public List<DatabaseInfo.ParamInfo> readParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("path", "ZNode Path", "text", true, "/")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> writeParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("path", "ZNode Path", "text", true, "/")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> deleteParams() {
        return readParams();
    }

    @Override
    public List<DatabaseInfo.ParamInfo> listParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("path", "Parent Path", "text", false, "/")
        );
    }

    // --- legacy ---

    public ZooKeeper getZooKeeper() throws Exception {
        ensureConnection();
        return zooKeeper;
    }

    private void ensureConnection() throws Exception {
        if (zooKeeper == null || !zooKeeper.getState().isAlive()) {
            log.info("[ZK] Connecting to {} ...", connectString);
            CountDownLatch latch = new CountDownLatch(1);
            zooKeeper = new ZooKeeper(connectString, sessionTimeoutMs, event -> {
                if (event.getState() == org.apache.zookeeper.Watcher.Event.KeeperState.SyncConnected) {
                    latch.countDown();
                }
            });
            if (!latch.await(sessionTimeoutMs, TimeUnit.MILLISECONDS)) {
                throw new RuntimeException("ZooKeeper connection timed out after " + sessionTimeoutMs + "ms");
            }
        }
    }

    @Override
    public void close() {
        if (zooKeeper != null) {
            try {
                zooKeeper.close();
                log.info("[ZK] Connection closed.");
            } catch (Exception e) {
                log.warn("[ZK] Error closing: {}", e.getMessage());
            }
        }
    }
}
