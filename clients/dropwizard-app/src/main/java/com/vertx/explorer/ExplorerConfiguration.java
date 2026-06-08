package com.vertx.explorer;

import com.fasterxml.jackson.annotation.JsonProperty;
import io.dropwizard.core.Configuration;

import java.util.LinkedHashMap;
import java.util.Map;

public class ExplorerConfiguration extends Configuration {

    @JsonProperty("databases")
    private Map<String, Map<String, Object>> databases = new LinkedHashMap<>();

    public Map<String, Map<String, Object>> getDatabases() {
        return databases;
    }

    public void setDatabases(Map<String, Map<String, Object>> databases) {
        this.databases = databases;
    }
}
