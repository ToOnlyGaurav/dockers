package com.vertx.explorer;

import com.vertx.aerospike.AerospikeDbClient;
import com.vertx.common.ClientRegistry;
import com.vertx.dockerregistry.DockerRegistryClient;
import com.vertx.explorer.resource.DatabaseResource;
import com.vertx.hbase.HBaseClient;
import com.vertx.mariadb.MariaDbClient;
import com.vertx.rmq.RmqClient;
import com.vertx.zookeeper.ZkClient;
import io.dropwizard.assets.AssetsBundle;
import io.dropwizard.core.Application;
import io.dropwizard.core.setup.Bootstrap;
import io.dropwizard.core.setup.Environment;

import java.util.Map;

public class ExplorerApplication extends Application<ExplorerConfiguration> {

    public static void main(String[] args) throws Exception {
        new ExplorerApplication().run(args);
    }

    @Override
    public String getName() {
        return "Database Explorer";
    }

    @Override
    public void initialize(Bootstrap<ExplorerConfiguration> bootstrap) {
        // Serve static UI assets at root path
        bootstrap.addBundle(new AssetsBundle("/assets/", "/", "index.html"));
    }

    @Override
    public void run(ExplorerConfiguration config, Environment environment) {
        // Build and register database clients if configured
        ClientRegistry registry = buildRegistry(config);
        environment.jersey().register(new DatabaseResource(registry));

        // Cleanup on shutdown
        environment.lifecycle().manage(new io.dropwizard.lifecycle.Managed() {
            @Override public void start() {}
            @Override public void stop() { registry.closeAll(); }
        });
    }

    private ClientRegistry buildRegistry(ExplorerConfiguration config) {
        ClientRegistry registry = new ClientRegistry();
        Map<String, Map<String, Object>> dbs = config.getDatabases();

        // If no databases configured, return empty registry
        if (dbs == null || dbs.isEmpty()) {
            return registry;
        }

        if (dbs.containsKey("aerospike")) {
            registry.register(new AerospikeDbClient(dbs.get("aerospike")));
        }
        if (dbs.containsKey("mariadb")) {
            registry.register(new MariaDbClient(dbs.get("mariadb")));
        }
        if (dbs.containsKey("rabbitmq")) {
            registry.register(new RmqClient(dbs.get("rabbitmq")));
        }
        if (dbs.containsKey("hbase")) {
            registry.register(new HBaseClient(dbs.get("hbase")));
        }
        if (dbs.containsKey("zookeeper")) {
            registry.register(new ZkClient(dbs.get("zookeeper")));
        }
        if (dbs.containsKey("docker-registry")) {
            registry.register(new DockerRegistryClient(dbs.get("docker-registry")));
        }

        return registry;
    }
}
