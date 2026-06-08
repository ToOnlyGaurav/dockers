package com.vertx.explorer.resource;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;

import java.util.HashMap;
import java.util.Map;

/**
 * Simple example REST resource for a vanilla Dropwizard application.
 * Demonstrates basic JAX-RS functionality without any external dependencies.
 */
@Path("/hello")
@Produces(MediaType.APPLICATION_JSON)
public class HelloResource {

    @GET
    public Map<String, Object> sayHello(@QueryParam("name") String name) {
        Map<String, Object> response = new HashMap<>();
        response.put("message", "Hello, " + (name != null ? name : "World") + "!");
        response.put("timestamp", System.currentTimeMillis());
        response.put("status", "success");
        return response;
    }

    @GET
    @Path("/ping")
    public Map<String, String> ping() {
        Map<String, String> response = new HashMap<>();
        response.put("status", "pong");
        return response;
    }
}
