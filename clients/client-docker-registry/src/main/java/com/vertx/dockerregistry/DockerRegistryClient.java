package com.vertx.dockerregistry;

import com.vertx.common.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.*;

public class DockerRegistryClient implements DatabaseClient {

    private static final Logger log = LoggerFactory.getLogger(DockerRegistryClient.class);

    private final String host;
    private final int port;
    private final String baseUrl;

    public DockerRegistryClient(Map<String, Object> config) {
        this.host = (String) config.getOrDefault("host", "localhost");
        this.port = (int) config.getOrDefault("port", 5000);
        this.baseUrl = String.format("http://%s:%d/v2", host, port);
    }

    @Override
    public String name() {
        return "docker-registry";
    }

    @Override
    public String validate() throws Exception {
        // Test connection by calling /v2/ endpoint
        makeRequest(baseUrl + "/");
        log.info("[DOCKER-REGISTRY] Connected to {}:{}", host, port);
        return String.format("Docker Registry OK - %s:%d", host, port);
    }

    /**
     * Browse - Returns raw JSON data for client-side parsing
     * The UI will parse this data using JavaScript
     */
    public Map<String, Object> browse(Map<String, String> params) throws Exception {
        Map<String, Object> result = new LinkedHashMap<>();
        
        // Get registry info
        result.put("registryUrl", baseUrl);
        result.put("host", host);
        result.put("port", port);
        
        // Get catalog - returns raw JSON string
        String catalogUrl = baseUrl + "/_catalog";
        String catalogJson = makeRequest(catalogUrl);
        result.put("catalogJson", catalogJson);
        
        // Get all repositories with their tags
        List<Map<String, Object>> repositories = new ArrayList<>();
        
        // Parse catalog manually (simple JSON parsing)
        if (catalogJson != null && catalogJson.contains("\"repositories\"")) {
            String[] parts = catalogJson.split("\"repositories\"\\s*:\\s*\\[");
            if (parts.length > 1) {
                String reposSection = parts[1].split("\\]")[0];
                String[] repoNames = reposSection.replaceAll("\"", "").split(",");
                
                for (String repoName : repoNames) {
                    repoName = repoName.trim();
                    if (!repoName.isEmpty()) {
                        Map<String, Object> repo = new LinkedHashMap<>();
                        repo.put("name", repoName);
                        
                        // Get tags for this repository
                        try {
                            String tagsUrl = baseUrl + "/" + repoName + "/tags/list";
                            String tagsJson = makeRequest(tagsUrl);
                            repo.put("tagsJson", tagsJson);
                            
                            // Parse tags count
                            int tagCount = countTags(tagsJson);
                            repo.put("tagCount", tagCount);
                            
                            // Get detailed tag info
                            List<Map<String, Object>> tags = getTagDetails(repoName, tagsJson);
                            repo.put("tags", tags);
                            
                        } catch (Exception e) {
                            log.warn("[DOCKER-REGISTRY] Error getting tags for {}: {}", repoName, e.getMessage());
                            repo.put("tagCount", 0);
                            repo.put("tags", Collections.emptyList());
                            repo.put("error", e.getMessage());
                        }
                        
                        repositories.add(repo);
                    }
                }
            }
        }
        
        result.put("repositories", repositories);
        result.put("totalRepositories", repositories.size());
        
        return result;
    }
    
    /**
     * Count tags from tags JSON
     */
    private int countTags(String tagsJson) {
        if (tagsJson == null || !tagsJson.contains("\"tags\"")) {
            return 0;
        }
        
        try {
            String[] parts = tagsJson.split("\"tags\"\\s*:\\s*\\[");
            if (parts.length > 1) {
                String tagsSection = parts[1].split("\\]")[0];
                if (tagsSection.trim().isEmpty()) {
                    return 0;
                }
                String[] tagNames = tagsSection.split(",");
                return tagNames.length;
            }
        } catch (Exception e) {
            log.debug("[DOCKER-REGISTRY] Error counting tags: {}", e.getMessage());
        }
        
        return 0;
    }
    
    /**
     * Get tag details
     */
    private List<Map<String, Object>> getTagDetails(String repository, String tagsJson) {
        List<Map<String, Object>> tags = new ArrayList<>();
        
        if (tagsJson == null || !tagsJson.contains("\"tags\"")) {
            return tags;
        }
        
        try {
            String[] parts = tagsJson.split("\"tags\"\\s*:\\s*\\[");
            if (parts.length > 1) {
                String tagsSection = parts[1].split("\\]")[0];
                String[] tagNames = tagsSection.replaceAll("\"", "").split(",");
                
                for (String tagName : tagNames) {
                    tagName = tagName.trim();
                    if (!tagName.isEmpty()) {
                        Map<String, Object> tag = new LinkedHashMap<>();
                        tag.put("name", tagName);
                        
                        // Try to get manifest
                        try {
                            Map<String, Object> manifest = getManifest(repository, tagName);
                            tag.putAll(manifest);
                        } catch (Exception e) {
                            log.debug("[DOCKER-REGISTRY] Could not get manifest for {}:{}", repository, tagName);
                        }
                        
                        tags.add(tag);
                    }
                }
            }
        } catch (Exception e) {
            log.warn("[DOCKER-REGISTRY] Error parsing tags: {}", e.getMessage());
        }
        
        return tags;
    }
    
    /**
     * Get manifest for a specific image tag
     */
    private Map<String, Object> getManifest(String repository, String tag) throws Exception {
        Map<String, Object> manifestInfo = new LinkedHashMap<>();
        
        String manifestUrl = baseUrl + "/" + repository + "/manifests/" + tag;
        
        // Make request with Accept header for manifest v2
        HttpURLConnection conn = (HttpURLConnection) new URL(manifestUrl).openConnection();
        conn.setRequestMethod("GET");
        conn.setRequestProperty("Accept", "application/vnd.docker.distribution.manifest.v2+json");
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(5000);
        
        // Get digest from header
        String digest = conn.getHeaderField("Docker-Content-Digest");
        if (digest != null) {
            manifestInfo.put("digest", digest);
        }
        
        // Read response
        StringBuilder response = new StringBuilder();
        try (BufferedReader in = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            String line;
            while ((line = in.readLine()) != null) {
                response.append(line);
            }
        }
        
        String manifestJson = response.toString();
        
        // Simple parsing for layers and size
        try {
            if (manifestJson.contains("\"layers\"")) {
                int layerCount = countJsonArrayItems(manifestJson, "\"layers\"");
                manifestInfo.put("layers", layerCount);
                
                long totalSize = calculateLayersSize(manifestJson);
                if (totalSize > 0) {
                    manifestInfo.put("size", totalSize);
                }
            }
            
            // Try to extract architecture and os from config
            if (manifestJson.contains("\"architecture\"")) {
                String arch = extractJsonValue(manifestJson, "\"architecture\"");
                if (arch != null) manifestInfo.put("architecture", arch);
            }
            if (manifestJson.contains("\"os\"")) {
                String os = extractJsonValue(manifestJson, "\"os\"");
                if (os != null) manifestInfo.put("os", os);
            }
        } catch (Exception e) {
            log.debug("[DOCKER-REGISTRY] Error parsing manifest: {}", e.getMessage());
        }
        
        return manifestInfo;
    }
    
    private int countJsonArrayItems(String json, String arrayName) {
        try {
            String[] parts = json.split(arrayName + "\\s*:\\s*\\[");
            if (parts.length > 1) {
                String arraySection = parts[1].split("\\]")[0];
                if (arraySection.trim().isEmpty() || arraySection.trim().equals("null")) {
                    return 0;
                }
                // Count objects by counting opening braces
                int count = 0;
                for (char c : arraySection.toCharArray()) {
                    if (c == '{') count++;
                }
                return count;
            }
        } catch (Exception e) {
            log.debug("Error counting array items: {}", e.getMessage());
        }
        return 0;
    }
    
    private long calculateLayersSize(String json) {
        long totalSize = 0;
        try {
            String[] sizeParts = json.split("\"size\"\\s*:\\s*");
            for (int i = 1; i < sizeParts.length; i++) {
                String sizeStr = sizeParts[i].split("[,}]")[0].trim();
                try {
                    totalSize += Long.parseLong(sizeStr);
                } catch (NumberFormatException e) {
                    // Skip invalid numbers
                }
            }
        } catch (Exception e) {
            log.debug("Error calculating size: {}", e.getMessage());
        }
        return totalSize;
    }
    
    private String extractJsonValue(String json, String key) {
        try {
            String[] parts = json.split(key + "\\s*:\\s*\"");
            if (parts.length > 1) {
                return parts[1].split("\"")[0];
            }
        } catch (Exception e) {
            log.debug("Error extracting value for {}: {}", key, e.getMessage());
        }
        return null;
    }
    
    /**
     * Make HTTP request to Docker Registry API
     */
    private String makeRequest(String urlString) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlString).openConnection();
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(10000);
        
        int responseCode = conn.getResponseCode();
        if (responseCode != 200) {
            throw new RuntimeException("HTTP error: " + responseCode);
        }
        
        StringBuilder response = new StringBuilder();
        try (BufferedReader in = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            String line;
            while ((line = in.readLine()) != null) {
                response.append(line);
            }
        }
        
        return response.toString();
    }

    @Override
    public void close() {
        log.info("[DOCKER-REGISTRY] Closed.");
    }
}
