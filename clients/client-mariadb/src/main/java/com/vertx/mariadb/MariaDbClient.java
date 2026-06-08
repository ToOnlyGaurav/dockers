package com.vertx.mariadb;

import com.vertx.common.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.*;
import java.util.*;

public class MariaDbClient implements DatabaseClient, QueryCapable, BrowsableCapable, DescribableClient {

    private static final Logger log = LoggerFactory.getLogger(MariaDbClient.class);

    private final String host;
    private final int port;
    private final String database;
    private final String username;
    private final String password;

    private Connection connection;
    private String currentDatabase; // Track the currently selected database

    public MariaDbClient(Map<String, Object> config) {
        this.host = (String) config.getOrDefault("host", "localhost");
        this.port = (int) config.getOrDefault("port", 3306);
        this.database = (String) config.getOrDefault("database", "test");
        this.username = (String) config.getOrDefault("username", "root");
        this.password = (String) config.getOrDefault("password", "root");
        this.currentDatabase = this.database; // Initialize with default database
    }

    @Override
    public String name() {
        return "mariadb";
    }

    @Override
    public String validate() throws Exception {
        ensureConnection();
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT 1")) {
            rs.next();
            String msg = String.format("MariaDB OK - connected to %s:%d/%s", host, port, database);
            log.info("[MARIADB] {}", msg);
            return msg;
        }
    }

    // --- QueryCapable ---

    @Override
    public List<Map<String, Object>> executeQuery(String query) throws Exception {
        ensureConnection();
        
        // Switch to the current database context if needed
        if (currentDatabase != null && !currentDatabase.equals(database)) {
            try (Statement useStmt = connection.createStatement()) {
                useStmt.execute("USE `" + currentDatabase + "`");
                log.debug("[MARIADB] Switched to database: {}", currentDatabase);
            }
        }
        
        List<Map<String, Object>> results = new ArrayList<>();
        try (Statement stmt = connection.createStatement()) {
            boolean hasResultSet = stmt.execute(query);
            if (hasResultSet) {
                try (ResultSet rs = stmt.getResultSet()) {
                    ResultSetMetaData meta = rs.getMetaData();
                    int cols = meta.getColumnCount();
                    while (rs.next()) {
                        Map<String, Object> row = new LinkedHashMap<>();
                        for (int i = 1; i <= cols; i++) {
                            row.put(meta.getColumnLabel(i), rs.getObject(i));
                        }
                        results.add(row);
                    }
                }
            } else {
                int updateCount = stmt.getUpdateCount();
                results.add(Map.of("_updateCount", updateCount));
            }
        }
        return results;
    }

    // --- BrowsableCapable ---

    @Override
    public List<String> listEntities(Map<String, String> params) throws Exception {
        ensureConnection();
        List<String> tables = new ArrayList<>();
        try (ResultSet rs = connection.getMetaData().getTables(database, null, "%", new String[]{"TABLE", "VIEW"})) {
            while (rs.next()) {
                tables.add(rs.getString("TABLE_NAME"));
            }
        }
        return tables;
    }

    @Override
    public Map<String, Object> describeEntity(String entity, Map<String, String> params) throws Exception {
        ensureConnection();
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("table", entity);
        List<Map<String, Object>> columns = new ArrayList<>();
        try (ResultSet rs = connection.getMetaData().getColumns(database, null, entity, "%")) {
            while (rs.next()) {
                Map<String, Object> col = new LinkedHashMap<>();
                col.put("name", rs.getString("COLUMN_NAME"));
                col.put("type", rs.getString("TYPE_NAME"));
                col.put("size", rs.getInt("COLUMN_SIZE"));
                col.put("nullable", rs.getString("IS_NULLABLE"));
                col.put("default", rs.getString("COLUMN_DEF"));
                columns.add(col);
            }
        }
        info.put("columns", columns);
        return info;
    }

    // --- DescribableClient ---

    @Override
    public List<DatabaseInfo.ParamInfo> listParams() {
        return List.of(); // no params needed, uses configured database
    }
    
    /**
     * Get comprehensive server information
     */
    public Map<String, Object> getServerInfo() throws Exception {
        ensureConnection();
        Map<String, Object> info = new LinkedHashMap<>();
        
        // Version and server info
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT VERSION() as version, @@hostname as hostname, @@port as port")) {
            if (rs.next()) {
                info.put("version", rs.getString("version"));
                info.put("hostname", rs.getString("hostname"));
                info.put("port", rs.getInt("port"));
            }
        }
        
        // Check if GTID is enabled (MariaDB uses gtid_domain_id instead of gtid_mode)
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT @@gtid_domain_id")) {
            if (rs.next()) {
                info.put("gtid_domain_id", rs.getInt(1));
                info.put("gtid_enabled", true);
            }
        } catch (Exception e) {
            info.put("gtid_enabled", false);
        }
        
        // Server status variables
        Map<String, Object> status = new LinkedHashMap<>();
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery("SHOW STATUS LIKE 'Uptime%'")) {
            while (rs.next()) {
                status.put(rs.getString(1), rs.getString(2));
            }
        }
        info.put("status", status);
        
        return info;
    }
    
    /**
     * List all databases
     */
    public List<Map<String, Object>> listDatabases() throws Exception {
        ensureConnection();
        List<Map<String, Object>> databases = new ArrayList<>();
        
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery(
                 "SELECT SCHEMA_NAME as name, " +
                 "DEFAULT_CHARACTER_SET_NAME as charset, " +
                 "DEFAULT_COLLATION_NAME as collation " +
                 "FROM information_schema.SCHEMATA " +
                 "ORDER BY SCHEMA_NAME")) {
            while (rs.next()) {
                Map<String, Object> db = new LinkedHashMap<>();
                db.put("name", rs.getString("name"));
                db.put("charset", rs.getString("charset"));
                db.put("collation", rs.getString("collation"));
                databases.add(db);
            }
        }
        
        return databases;
    }
    
    /**
     * Get tables for a specific database
     */
    public List<Map<String, Object>> listTablesWithDetails(String dbName) throws Exception {
        ensureConnection();
        List<Map<String, Object>> tables = new ArrayList<>();
        
        String db = dbName != null && !dbName.isEmpty() ? dbName : database;
        
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery(
                 "SELECT TABLE_NAME as name, " +
                 "TABLE_TYPE as type, " +
                 "ENGINE as engine, " +
                 "TABLE_ROWS as row_count, " +
                 "DATA_LENGTH as data_length, " +
                 "INDEX_LENGTH as index_length, " +
                 "CREATE_TIME as created, " +
                 "UPDATE_TIME as updated " +
                 "FROM information_schema.TABLES " +
                 "WHERE TABLE_SCHEMA = '" + db + "' " +
                 "ORDER BY TABLE_NAME")) {
            while (rs.next()) {
                Map<String, Object> table = new LinkedHashMap<>();
                table.put("name", rs.getString("name"));
                table.put("type", rs.getString("type"));
                table.put("engine", rs.getString("engine"));
                table.put("rows", rs.getLong("row_count"));
                table.put("dataSize", rs.getLong("data_length"));
                table.put("indexSize", rs.getLong("index_length"));
                table.put("totalSize", rs.getLong("data_length") + rs.getLong("index_length"));
                table.put("created", rs.getTimestamp("created"));
                table.put("updated", rs.getTimestamp("updated"));
                tables.add(table);
            }
        }
        
        return tables;
    }
    
    /**
     * List all users and their grants
     */
    public List<Map<String, Object>> listUsers() throws Exception {
        ensureConnection();
        List<Map<String, Object>> users = new ArrayList<>();
        
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery(
                 "SELECT User as username, Host as host, " +
                 "Select_priv, Insert_priv, Update_priv, Delete_priv, " +
                 "Create_priv, Drop_priv, Grant_priv, Super_priv " +
                 "FROM mysql.user " +
                 "ORDER BY User, Host")) {
            while (rs.next()) {
                Map<String, Object> user = new LinkedHashMap<>();
                user.put("username", rs.getString("username"));
                user.put("host", rs.getString("host"));
                user.put("fullName", rs.getString("username") + "@" + rs.getString("host"));
                
                Map<String, Boolean> privileges = new LinkedHashMap<>();
                privileges.put("SELECT", "Y".equals(rs.getString("Select_priv")));
                privileges.put("INSERT", "Y".equals(rs.getString("Insert_priv")));
                privileges.put("UPDATE", "Y".equals(rs.getString("Update_priv")));
                privileges.put("DELETE", "Y".equals(rs.getString("Delete_priv")));
                privileges.put("CREATE", "Y".equals(rs.getString("Create_priv")));
                privileges.put("DROP", "Y".equals(rs.getString("Drop_priv")));
                privileges.put("GRANT", "Y".equals(rs.getString("Grant_priv")));
                privileges.put("SUPER", "Y".equals(rs.getString("Super_priv")));
                
                user.put("privileges", privileges);
                users.add(user);
            }
        }
        
        return users;
    }
    
    /**
     * Get detailed grants for a specific user
     */
    public List<String> getUserGrants(String username, String host) throws Exception {
        ensureConnection();
        List<String> grants = new ArrayList<>();
        
        try (Statement stmt = connection.createStatement();
             ResultSet rs = stmt.executeQuery("SHOW GRANTS FOR '" + username + "'@'" + host + "'")) {
            while (rs.next()) {
                grants.add(rs.getString(1));
            }
        } catch (Exception e) {
            grants.add("Error: " + e.getMessage());
        }
        
        return grants;
    }
    
    /**
     * Browse - comprehensive database overview
     */
    public Map<String, Object> browse(Map<String, String> params) throws Exception {
        ensureConnection();
        Map<String, Object> result = new LinkedHashMap<>();
        
        // Update current database if specified in params
        String requestedDb = params.getOrDefault("database", database);
        if (requestedDb != null && !requestedDb.isEmpty()) {
            this.currentDatabase = requestedDb;
            log.info("[MARIADB] Switched context to database: {}", currentDatabase);
        }
        
        // Server info
        result.put("serverInfo", getServerInfo());
        
        // All databases
        result.put("databases", listDatabases());
        
        // Current database tables
        result.put("currentDatabase", currentDatabase);
        result.put("tables", listTablesWithDetails(currentDatabase));
        
        // Users
        result.put("users", listUsers());
        
        return result;
    }

    // --- legacy ---

    public Connection getConnection() throws Exception {
        ensureConnection();
        return connection;
    }

    private void ensureConnection() throws Exception {
        if (connection == null || connection.isClosed()) {
            String url = String.format("jdbc:mariadb://%s:%d/%s", host, port, database);
            log.info("[MARIADB] Connecting to {} ...", url);
            connection = DriverManager.getConnection(url, username, password);
        }
    }

    @Override
    public void close() {
        if (connection != null) {
            try {
                connection.close();
                log.info("[MARIADB] Connection closed.");
            } catch (Exception e) {
                log.warn("[MARIADB] Error closing: {}", e.getMessage());
            }
        }
    }
}
