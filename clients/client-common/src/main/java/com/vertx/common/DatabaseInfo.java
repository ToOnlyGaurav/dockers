package com.vertx.common;

import java.util.List;
import java.util.Map;

/**
 * Self-describing metadata about a database client.
 * Used by the UI to dynamically render forms and actions.
 */
public class DatabaseInfo {

    private final String name;
    private final boolean healthy;
    private final String statusMessage;
    private final List<String> capabilities;
    private final Map<String, List<ParamInfo>> actionParams;

    public DatabaseInfo(String name, boolean healthy, String statusMessage,
                        List<String> capabilities, Map<String, List<ParamInfo>> actionParams) {
        this.name = name;
        this.healthy = healthy;
        this.statusMessage = statusMessage;
        this.capabilities = capabilities;
        this.actionParams = actionParams;
    }

    public String getName() { return name; }
    public boolean isHealthy() { return healthy; }
    public String getStatusMessage() { return statusMessage; }
    public List<String> getCapabilities() { return capabilities; }
    public Map<String, List<ParamInfo>> getActionParams() { return actionParams; }

    /**
     * Describes a parameter needed for an action.
     */
    public static class ParamInfo {
        private final String name;
        private final String label;
        private final String type; // "text", "textarea", "number"
        private final boolean required;
        private final String defaultValue;

        public ParamInfo(String name, String label, String type, boolean required, String defaultValue) {
            this.name = name;
            this.label = label;
            this.type = type;
            this.required = required;
            this.defaultValue = defaultValue;
        }

        public String getName() { return name; }
        public String getLabel() { return label; }
        public String getType() { return type; }
        public boolean isRequired() { return required; }
        public String getDefaultValue() { return defaultValue; }
    }
}
