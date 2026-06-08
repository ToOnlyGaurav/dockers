#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/dropwizard-app"
JAR="$APP_DIR/target/dropwizard-app-1.0-SNAPSHOT.jar"
CONFIG="${2:-$SCRIPT_DIR/test.yml}"

build() {
    echo "Building..."
    mvn clean package -pl dropwizard-app -am -q -DskipTests -f "$SCRIPT_DIR/pom.xml"
    if [ $? -ne 0 ]; then
        echo "Build failed."
        exit 1
    fi
    echo "Build complete."
}

run() {
    if [ ! -f "$JAR" ]; then
        echo "JAR not found. Building first..."
        build
    fi
    echo "Starting Dropwizard Application..."
    echo "Config: $CONFIG"
    echo "Application: http://localhost:8080"
    echo "Admin: http://localhost:8081"
    java -jar "$JAR" server "$CONFIG"
}

case "${1:-run}" in
    build) build ;;
    run)   run ;;
    rebuild)
        build
        run
        ;;
    *)
        echo "Usage: $0 {build|run|rebuild} [config.yml]"
        echo "  build   - Build the application"
        echo "  run     - Run the application (default)"
        echo "  rebuild - Clean build and run"
        echo ""
        echo "Examples:"
        echo "  $0 run"
        echo "  $0 run test.yml"
        echo "  $0 run dropwizard-app/config/config.yml"
        exit 1
        ;;
esac
