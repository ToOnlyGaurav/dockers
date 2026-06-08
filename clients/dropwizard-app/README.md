# Pure Vanilla Dropwizard Application

This directory contains a clean Dropwizard application without any PhonePe-specific constructs.

## What's Included

- ✅ **Pure Dropwizard 4.0.7** - Latest stable version
- ✅ **Simple REST API** - Basic JAX-RS resources
- ✅ **Health Checks** - Built-in monitoring
- ✅ **Metrics** - Application metrics
- ✅ **Clean Configuration** - No external service dependencies

## What's NOT Included

- ❌ No Ranger / Service Discovery
- ❌ No Olympus / PhonePe Authentication
- ❌ No Fisheye / PhonePe Logging
- ❌ No SpyGlass / PhonePe Monitoring
- ❌ No PhonePe-specific libraries

## Quick Start

### 1. Build

```bash
cd /Users/gaurav.prasad/github/local/dockers/clients
mvn clean package -pl dropwizard-app -am
```

### 2. Run

```bash
# Using the simple config.yml configuration
./run.sh run

# Or specify a custom config
./run.sh run dropwizard-app/config/config.yml
```

### 3. Test

```bash
# Hello endpoint
curl http://localhost:8080/hello
curl http://localhost:8080/hello?name=John

# Ping endpoint
curl http://localhost:8080/hello/ping

# Health check
curl http://localhost:8081/healthcheck

# Metrics
curl http://localhost:8081/metrics
```

## Configuration Files

### `test.yml` - Minimal Configuration

Located at the project root, this is the simplest possible configuration:

```yaml
server:
  applicationConnectors:
    - type: http
      port: 8080
  adminConnectors:
    - type: http
      port: 8081

logging:
  level: INFO
  appenders:
    - type: console

databases: {}
```

### `dropwizard-app/config.yml` - Detailed Configuration

Includes more options and examples:

```yaml
server:
  applicationConnectors:
    - type: http
      port: 8080
      bindHost: 0.0.0.0
  adminConnectors:
    - type: http
      port: 8081
      bindHost: 0.0.0.0

logging:
  level: INFO
  loggers:
    com.vertx: DEBUG
  appenders:
    - type: console

databases: {}
```

## Project Structure

```
dropwizard-app/
├── pom.xml                                 # Maven configuration
├── config.yml                              # Application configuration
└── src/main/java/com/vertx/explorer/
    ├── ExplorerApplication.java            # Main Dropwizard app
    ├── ExplorerConfiguration.java          # Configuration class
    ├── HelloResource.java                  # Simple REST endpoint
    └── DatabaseResource.java               # Database operations (optional)
```

## Key Classes

### ExplorerApplication.java

The main entry point. Extends `Application<ExplorerConfiguration>`:

```java
public class ExplorerApplication extends Application<ExplorerConfiguration> {
    public static void main(String[] args) throws Exception {
        new ExplorerApplication().run(args);
    }
    
    @Override
    public void run(ExplorerConfiguration config, Environment environment) {
        // Register REST resources
        environment.jersey().register(new HelloResource());
    }
}
```

### ExplorerConfiguration.java

Configuration POJO that maps to your YAML file:

```java
public class ExplorerConfiguration extends Configuration {
    @JsonProperty("databases")
    private Map<String, Map<String, Object>> databases = new LinkedHashMap<>();
    
    // Getters and setters
}
```

### HelloResource.java

A simple JAX-RS resource demonstrating REST endpoints:

```java
@Path("/hello")
@Produces(MediaType.APPLICATION_JSON)
public class HelloResource {
    
    @GET
    public Map<String, Object> sayHello(@QueryParam("name") String name) {
        Map<String, Object> response = new HashMap<>();
        response.put("message", "Hello, " + (name != null ? name : "World") + "!");
        response.put("timestamp", System.currentTimeMillis());
        return response;
    }
}
```

## Adding Your Own Resources

1. Create a new Java class in `com.vertx.explorer`:

```java
package com.vertx.explorer;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;

@Path("/api/users")
@Produces(MediaType.APPLICATION_JSON)
public class UserResource {
    
    @GET
    public List<User> getUsers() {
        // Your logic here
    }
    
    @POST
    @Consumes(MediaType.APPLICATION_JSON)
    public User createUser(User user) {
        // Your logic here
    }
}
```

2. Register it in `ExplorerApplication.java`:

```java
@Override
public void run(ExplorerConfiguration config, Environment environment) {
    environment.jersey().register(new UserResource());
}
```

## Adding Custom Configuration

1. Add fields to `ExplorerConfiguration.java`:

```java
public class ExplorerConfiguration extends Configuration {
    
    @JsonProperty("myCustomField")
    private String myCustomField;
    
    public String getMyCustomField() {
        return myCustomField;
    }
}
```

2. Use it in your YAML:

```yaml
myCustomField: "some value"
```

3. Access it in your application:

```java
@Override
public void run(ExplorerConfiguration config, Environment environment) {
    String value = config.getMyCustomField();
}
```

## Maven Dependencies (Minimal)

The only required dependencies are:

```xml
<dependency>
    <groupId>io.dropwizard</groupId>
    <artifactId>dropwizard-core</artifactId>
    <version>4.0.7</version>
</dependency>
```

For serving static files (optional):

```xml
<dependency>
    <groupId>io.dropwizard</groupId>
    <artifactId>dropwizard-assets</artifactId>
    <version>4.0.7</version>
</dependency>
```

## API Endpoints

### Application (Port 8080)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/hello` | Returns a greeting message |
| GET | `/hello?name=John` | Returns a personalized greeting |
| GET | `/hello/ping` | Health ping endpoint |
| GET | `/databases` | List configured databases (if any) |
| POST | `/databases/{name}/execute` | Execute database operations |

### Admin (Port 8081)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/healthcheck` | Application health status |
| GET | `/metrics` | Application metrics |
| GET | `/threads` | Thread dump |
| GET | `/ping` | Simple ping |

## Common Issues

### Port Already in Use

Change the ports in your config file:

```yaml
server:
  applicationConnectors:
    - type: http
      port: 9090
  adminConnectors:
    - type: http
      port: 9091
```

### YAML Parsing Error

- Always quote values with special characters: `value: "{{VARIABLE}}"`
- Use spaces for indentation, not tabs
- Validate YAML: `python3 -c "import yaml; yaml.safe_load(open('config.yml'))"`

## Next Steps

1. **Add Database Support**: Uncomment database configs and add client dependencies
2. **Add Authentication**: Use `dropwizard-auth` module
3. **Add CORS**: Use `dropwizard-cors` bundle
4. **Add Swagger**: Use `dropwizard-swagger` for API documentation
5. **Add Testing**: Write integration tests with `DropwizardTestSupport`

## Resources

- [Dropwizard Documentation](https://www.dropwizard.io/en/latest/)
- [JAX-RS Tutorial](https://docs.oracle.com/javaee/7/tutorial/jaxrs.htm)
- [Jackson JSON](https://github.com/FasterXML/jackson)
- [Jersey REST Framework](https://eclipse-ee4j.github.io/jersey/)
