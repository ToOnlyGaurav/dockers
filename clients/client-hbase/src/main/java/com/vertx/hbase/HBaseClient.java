package com.vertx.hbase;

import com.vertx.common.*;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.*;
import org.apache.hadoop.hbase.util.Bytes;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.*;

public class HBaseClient implements DatabaseClient, CrudCapable, BrowsableCapable, DescribableClient {

    private static final Logger log = LoggerFactory.getLogger(HBaseClient.class);

    private final String zkQuorum;
    private final String zkPort;

    private org.apache.hadoop.hbase.client.Connection connection;

    public HBaseClient(Map<String, Object> config) {
        this.zkQuorum = (String) config.getOrDefault("zkQuorum", "localhost");
        this.zkPort = String.valueOf(config.getOrDefault("zkPort", 2181));
    }

    @Override
    public String name() {
        return "hbase";
    }

    @Override
    public String validate() throws Exception {
        ensureConnection();
        try (Admin admin = connection.getAdmin()) {
            TableName[] tables = admin.listTableNames();
            String msg = String.format("HBase OK - connected via ZK %s:%s, %d table(s) found",
                    zkQuorum, zkPort, tables.length);
            log.info("[HBASE] {}", msg);
            return msg;
        }
    }

    // --- CrudCapable ---

    @Override
    public Map<String, Object> read(Map<String, String> params) throws Exception {
        ensureConnection();
        String tableName = params.get("table");
        String rowKey = params.get("rowkey");
        if (tableName == null || rowKey == null) throw new IllegalArgumentException("'table' and 'rowkey' are required");

        try (Table table = connection.getTable(TableName.valueOf(tableName))) {
            Get get = new Get(Bytes.toBytes(rowKey));
            Result result = table.get(get);
            if (result.isEmpty()) return Map.of("_found", false);

            Map<String, Object> data = new LinkedHashMap<>();
            data.put("_found", true);
            result.getNoVersionMap().forEach((family, qualifiers) -> {
                String cf = Bytes.toString(family);
                qualifiers.forEach((qualifier, val) -> {
                    data.put(cf + ":" + Bytes.toString(qualifier), Bytes.toString(val));
                });
            });
            return data;
        }
    }

    @Override
    public void write(Map<String, String> params, Map<String, Object> value) throws Exception {
        ensureConnection();
        String tableName = params.get("table");
        String rowKey = params.get("rowkey");
        String cf = params.getOrDefault("columnFamily", "cf");
        if (tableName == null || rowKey == null) throw new IllegalArgumentException("'table' and 'rowkey' are required");

        try (Table table = connection.getTable(TableName.valueOf(tableName))) {
            Put put = new Put(Bytes.toBytes(rowKey));
            value.forEach((qualifier, val) ->
                put.addColumn(Bytes.toBytes(cf), Bytes.toBytes(qualifier), Bytes.toBytes(String.valueOf(val)))
            );
            table.put(put);
            log.info("[HBASE] PUT table={}, rowkey={}, cf={}, cols={}", tableName, rowKey, cf, value.keySet());
        }
    }

    @Override
    public void delete(Map<String, String> params) throws Exception {
        ensureConnection();
        String tableName = params.get("table");
        String rowKey = params.get("rowkey");
        if (tableName == null || rowKey == null) throw new IllegalArgumentException("'table' and 'rowkey' are required");

        try (Table table = connection.getTable(TableName.valueOf(tableName))) {
            Delete delete = new Delete(Bytes.toBytes(rowKey));
            table.delete(delete);
            log.info("[HBASE] DELETE table={}, rowkey={}", tableName, rowKey);
        }
    }

    // --- BrowsableCapable ---

    @Override
    public List<String> listEntities(Map<String, String> params) throws Exception {
        ensureConnection();
        try (Admin admin = connection.getAdmin()) {
            TableName[] tables = admin.listTableNames();
            List<String> names = new ArrayList<>();
            for (TableName t : tables) names.add(t.getNameAsString());
            return names;
        }
    }

    @Override
    public Map<String, Object> describeEntity(String entity, Map<String, String> params) throws Exception {
        ensureConnection();
        try (Admin admin = connection.getAdmin()) {
            TableDescriptor desc = admin.getDescriptor(TableName.valueOf(entity));
            Map<String, Object> info = new LinkedHashMap<>();
            info.put("table", entity);
            List<String> families = new ArrayList<>();
            for (ColumnFamilyDescriptor cf : desc.getColumnFamilies()) {
                families.add(cf.getNameAsString());
            }
            info.put("columnFamilies", families);
            info.put("enabled", admin.isTableEnabled(TableName.valueOf(entity)));
            return info;
        }
    }

    // --- DescribableClient ---

    @Override
    public List<DatabaseInfo.ParamInfo> readParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("table", "Table Name", "text", true, ""),
            new DatabaseInfo.ParamInfo("rowkey", "Row Key", "text", true, "")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> writeParams() {
        return List.of(
            new DatabaseInfo.ParamInfo("table", "Table Name", "text", true, ""),
            new DatabaseInfo.ParamInfo("rowkey", "Row Key", "text", true, ""),
            new DatabaseInfo.ParamInfo("columnFamily", "Column Family", "text", false, "cf")
        );
    }

    @Override
    public List<DatabaseInfo.ParamInfo> deleteParams() {
        return readParams();
    }

    @Override
    public List<DatabaseInfo.ParamInfo> listParams() {
        return List.of();
    }

    // --- legacy ---

    public org.apache.hadoop.hbase.client.Connection getConnection() throws Exception {
        ensureConnection();
        return connection;
    }

    private void ensureConnection() throws Exception {
        if (connection == null || connection.isClosed()) {
            log.info("[HBASE] Connecting via ZK {}:{} ...", zkQuorum, zkPort);
            Configuration conf = HBaseConfiguration.create();
            conf.set("hbase.zookeeper.quorum", zkQuorum);
            conf.set("hbase.zookeeper.property.clientPort", zkPort);
            connection = ConnectionFactory.createConnection(conf);
        }
    }

    @Override
    public void close() {
        if (connection != null) {
            try {
                connection.close();
                log.info("[HBASE] Connection closed.");
            } catch (Exception e) {
                log.warn("[HBASE] Error closing: {}", e.getMessage());
            }
        }
    }
}
