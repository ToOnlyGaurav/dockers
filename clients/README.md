# Database Explorer - Web UI Application

A comprehensive **web-based database explorer** that provides a visual interface to connect to, explore, and interact with multiple databases (Aerospike, MariaDB, RabbitMQ, HBase, ZooKeeper) through a clean, modern UI.

---

## Features

### 🎯 Core Features

- **Multi-Database Support**: Connect to multiple database types simultaneously
- **Visual Web Interface**: Clean, modern UI for database exploration
- **Database Discovery**: Automatically shows available databases and their health status
- **Cluster Information**: View database version, nodes, tables, and other metadata
- **CRUD Operations**: Perform Create, Read, Update, Delete operations
- **Database-Specific Operations**: Execute database-specific commands and queries
- **Real-time Health Monitoring**: See connection status for each database

### 📊 Supported Databases

| Database | Capabilities | Operations |
|----------|-------------|------------|
| **Aerospike** | CRUD, Browse | Read, Write, Delete, List, Describe |
| **MariaDB** | Query, CRUD | Execute SQL, Browse tables |
| **RabbitMQ** | Pub/Sub, Browse | Publish, Consume, List queues |
| **HBase** | CRUD, Browse | Get, Put, Delete, Scan tables |
| **ZooKeeper** | CRUD, Browse | Read, Write, Delete, List nodes |

---

## Quick Start

### 1. Build the Application

```bash
cd /Users/gaurav.prasad/github/local/dockers/clients
mvn clean package
```

### 2. Configure Databases

Edit `config.yml` to add your database connections:

```yaml
databases:
  aerospike:
    hosts: "localhost:3000"
    namespace: "test"
  
  mariadb:
    url: "jdbc:mysql://localhost:3306/mydb"
    username: "root"
    password: "password"
```

### 3. Run the Application

```bash
# Using the run script
./run.sh run

# Or directly with java
java -jar dropwizard-app/target/dropwizard-app-1.0-SNAPSHOT.jar server test.yml
```

### 4. Access the Web UI

Open your browser and navigate to:
- **Web UI**: http://localhost:8080
- **API**: http://localhost:8080/api
- **Admin Console**: http://localhost:8081

---

## Using the Web Interface

### Step 1: Select a Database

<img src="docs/select-database.png" alt="Select Database" width="600"/>

1. Open http://localhost:8080 in your browser
2. Use the dropdown in the header to select a database
3. The UI will show the connection status (Connected/Disconnected)

### Step 2: View Database Information

Once selected, you'll see:
- **Connection Status**: Whether the database is healthy
- **Capabilities**: What operations are supported (CRUD, Browse, Query, Pub/Sub)
- **Cluster Info**: Nodes, version, and other metadata

### Step 3: Perform Operations

Click on capability tabs to see available operations:

#### CRUD Operations
- **Read**: Retrieve records by key
- **Write**: Insert or update records
- **Delete**: Remove records

#### Browse Operations
- **List Entities**: See all tables/namespaces/queues
- **Describe**: Get detailed information about an entity

#### Query Operations
- **Execute Query**: Run SQL or database-specific queries

#### Pub/Sub Operations (RabbitMQ)
- **Publish**: Send messages to queues
- **Consume**: Read messages from queues

---

## Configuration Examples

### Minimal Configuration (No Databases)

```yaml
server:
  applicationConnectors:
    - type: http
      port: 8080
  adminConnectors:
    - type: http
      port: 8081
  rootPath: /api/*

logging:
  level: INFO
  appenders:
    - type: console

databases: {}
```

### Full Configuration with All Databases

```yaml
server:
  applicationConnectors:
    - type: http
      port: 8080
  adminConnectors:
    - type: http
      port: 8081
  rootPath: /api/*

logging:
  level: INFO
  loggers:
    com.vertx: DEBUG
  appenders:
    - type: console

databases:
  # Aerospike NoSQL Database
  aerospike:
    hosts: "localhost:3000,localhost:3001,localhost:3002"
    namespace: "test"
    timeout: 5000
    maxConnectionsPerNode: 100

  # MariaDB Relational Database
  mariadb:
    url: "jdbc:mysql://localhost:3306/mydb?useSSL=false"
    username: "root"
    password: "password"
    driverClass: "org.mariadb.jdbc.Driver"
    maxPoolSize: 10

  # RabbitMQ Message Broker
  rabbitmq:
    host: "localhost"
    port: 5672
    username: "guest"
    password: "guest"
    virtualHost: "/"

  # Apache HBase
  hbase:
    zookeeperQuorum: "localhost"
    zookeeperPort: 2181
    znode: "/hbase"

  # Apache ZooKeeper
  zookeeper:
    connectString: "localhost:2181"
    sessionTimeout: 15000
    connectionTimeout: 5000
```

---

## API Endpoints

The application exposes a REST API that the web UI uses:

### List All Databases

```bash
GET /api/databases
```

Returns information about all configured databases, their health status, and capabilities.

**Response:**
```json
[
  {
    "name": "aerospike",
    "type": "Aerospike",
    "healthy": true,
    "statusMessage": "Connected to localhost:3000",
    "capabilities": ["crud", "browse"],
    "metadata": {
      "nodes": ["localhost:3000"],
      "namespace": "test"
    }
  }
]
```

### Get Database Details

```bash
GET /api/databases/{name}
```

Returns detailed information about a specific database.

### Execute Operations

```bash
POST /api/databases/{name}/execute
Content-Type: application/json

{
  "action": "read",
  "params": {
    "key": "mykey",
    "set": "myset"
  }
}
```

**Supported actions:**
- `read`, `write`, `delete` (CRUD)
- `list`, `describe` (Browse)
- `query` (Query)
- `publish`, `consume` (Pub/Sub)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Web Browser                          │
│              http://localhost:8080                       │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ HTTP/REST
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Dropwizard Application                      │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Static Assets (HTML/CSS/JS)                      │  │
│  │  - index.html, app.js, style.css                  │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  REST API (/api/*)                                │  │
│  │  - DatabaseResource (Jersey)                      │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Client Registry                                  │  │
│  │  - AerospikeDbClient                             │  │
│  │  - MariaDbClient                                 │  │
│  │  - RmqClient                                     │  │
│  │  - HBaseClient                                   │  │
│  │  - ZkClient                                      │  │
│  └───────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────┘
                     │
         ┌───────────┴───────────┐
         ▼           ▼           ▼
    [Aerospike]  [MariaDB]  [RabbitMQ] [HBase] [ZooKeeper]
```

---

## Project Structure

```
dropwizard-app/
├── pom.xml
├── src/main/
│   ├── java/com/vertx/explorer/
│   │   ├── ExplorerApplication.java     # Main Dropwizard app
│   │   ├── ExplorerConfiguration.java   # Configuration class
│   │   └── DatabaseResource.java        # REST API endpoints
│   └── resources/
│       ├── assets/
│       │   ├── index.html              # Main UI page
│       │   ├── app.js                  # JavaScript logic
│       │   └── style.css               # Styling
│       └── config.yml                  # Example configuration
└── target/
    └── dropwizard-app-1.0-SNAPSHOT.jar # Executable JAR
```

---

## Development

### Adding a New Database Client

1. Create a new module in `client-{database}/`
2. Implement the `DatabaseClient` interface from `client-common`
3. Add the client to `ExplorerApplication.buildRegistry()`

### Customizing the UI

Edit the files in `src/main/resources/assets/`:
- `index.html` - HTML structure
- `app.js` - JavaScript application logic
- `style.css` - Styling and layout

### Adding New Operations

1. Add the operation to your database client's capabilities
2. Implement the operation in the client class
3. The UI will automatically detect and display it

---

## Troubleshooting

### Port Already in Use

```yaml
server:
  applicationConnectors:
    - type: http
      port: 9090  # Change port
```

### Database Connection Failed

Check:
1. Database is running: `telnet localhost 3000`
2. Credentials are correct in config
3. Firewall allows connections
4. Database-specific logs in console

### UI Not Loading

1. Check `http://localhost:8080` loads the HTML
2. Check browser console for JavaScript errors
3. Verify API responds: `curl http://localhost:8080/api/databases`

### YAML Configuration Error

```bash
# Validate YAML syntax
python3 -c "import yaml; yaml.safe_load(open('test.yml'))"
```

---

## Screenshots

### Database Selection
The dropdown shows all configured databases with their status.

### Aerospike Explorer
- Browse namespaces and sets
- Read/Write/Delete records
- View cluster nodes and health

### MariaDB Query Interface
- Execute SQL queries
- Browse tables and schemas
- View query results in table format

### RabbitMQ Console
- List queues and exchanges
- Publish messages
- Consume and view messages

---

## Next Steps

1. **Add More Databases**: Support for MongoDB, Redis, PostgreSQL, etc.
2. **Advanced Queries**: Query builder interface
3. **Data Visualization**: Charts and graphs for analytics
4. **Export/Import**: Backup and restore data
5. **Authentication**: Add user login and permissions
6. **Connection Pooling**: Better performance for SQL databases

---

## Resources

- **Dropwizard**: https://www.dropwizard.io/
- **Aerospike**: https://aerospike.com/
- **MariaDB**: https://mariadb.org/
- **RabbitMQ**: https://www.rabbitmq.com/
- **HBase**: https://hbase.apache.org/
- **ZooKeeper**: https://zookeeper.apache.org/

---

## License

MIT
