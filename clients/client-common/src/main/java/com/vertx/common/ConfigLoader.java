package com.vertx.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.yaml.snakeyaml.Yaml;

import java.io.InputStream;
import java.util.Collections;
import java.util.Map;

/**
 * Loads config.yml and provides per-section access.
 * Missing sections return empty maps instead of failing,
 * so you can validate one DB even if others aren't configured.
 */
public class ConfigLoader {

    private static final Logger log = LoggerFactory.getLogger(ConfigLoader.class);
    private static final String CONFIG_FILE = "config.yml";

    private final Map<String, Object> root;

    public ConfigLoader() {
        this(CONFIG_FILE);
    }

    @SuppressWarnings("unchecked")
    public ConfigLoader(String configFile) {
        Yaml yaml = new Yaml();
        try (InputStream in = getClass().getClassLoader().getResourceAsStream(configFile)) {
            if (in == null) {
                log.warn("Config file '{}' not found on classpath. Using empty config.", configFile);
                root = Collections.emptyMap();
            } else {
                Map<String, Object> loaded = yaml.load(in);
                root = loaded != null ? loaded : Collections.emptyMap();
                log.info("Loaded config from '{}'", configFile);
            }
        } catch (Exception e) {
            throw new RuntimeException("Failed to load config: " + e.getMessage(), e);
        }
    }

    /**
     * Returns the config map for a given section (e.g. "rabbitmq", "aerospike").
     * Returns empty map if the section is missing - never throws.
     */
    @SuppressWarnings("unchecked")
    public Map<String, Object> getSection(String name) {
        Object section = root.get(name);
        if (section instanceof Map) {
            return (Map<String, Object>) section;
        }
        return Collections.emptyMap();
    }

    public boolean hasSection(String name) {
        return root.containsKey(name);
    }
}
