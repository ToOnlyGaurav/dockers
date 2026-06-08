package com.vertx.explorer.resource;

import com.vertx.common.ClientRegistry;
import com.vertx.common.DatabaseInfo;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.List;
import java.util.Map;

@Path("/databases")
@Produces(MediaType.APPLICATION_JSON)
public class DatabaseResource {

    private final ClientRegistry registry;

    public DatabaseResource(ClientRegistry registry) {
        this.registry = registry;
    }

    /** List all registered databases with health status and capabilities. */
    @GET
    public List<DatabaseInfo> listDatabases() {
        return registry.listDatabases();
    }

    /** Get metadata for a single database (no health check). */
    @GET
    @Path("/{name}")
    public Response describeDatabase(@PathParam("name") String name) {
        DatabaseInfo info = registry.describeDatabase(name);
        if (info == null) {
            return Response.status(404).entity(Map.of("error", "Unknown database: " + name)).build();
        }
        return Response.ok(info).build();
    }

    /**
     * Generic action executor. The UI sends all operations through this endpoint.
     * Body: { "action": "read|write|delete|list|describe|query|publish|consume|validate",
     *         "params": {...}, "value": {...}, "query": "...", "target": "...", "message": "..." }
     */
    @POST
    @Path("/{name}/execute")
    @Consumes(MediaType.APPLICATION_JSON)
    public Response execute(@PathParam("name") String name, Map<String, Object> payload) {
        try {
            String action = (String) payload.get("action");
            if (action == null || action.isBlank()) {
                return Response.status(400).entity(Map.of("error", "'action' is required")).build();
            }
            Object result = registry.execute(name, action, payload);
            return Response.ok(result).build();
        } catch (IllegalArgumentException e) {
            return Response.status(400).entity(Map.of("error", e.getMessage())).build();
        } catch (Exception e) {
            return Response.status(500).entity(Map.of("error", e.getClass().getSimpleName() + ": " + e.getMessage())).build();
        }
    }
}
