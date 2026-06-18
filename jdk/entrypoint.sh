#!/bin/bash

# Source SDKMAN if available
if [ -f "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  echo "SDKMAN loaded: $(sdk version 2>/dev/null)"
fi

# JAVA_HOME and PATH are already injected by Docker ENV (set in Dockerfile).
# This script just validates and displays the configuration.
if [ -z "${JAVA_HOME}" ] || [ ! -d "${JAVA_HOME}" ]; then
  echo "ERROR: JAVA_HOME is not set or directory does not exist: ${JAVA_HOME}"
  echo "Contents of /remote:"
  ls /remote
  exit 1
fi

echo "JAVA_HOME=${JAVA_HOME}"
java -version

# Execute the passed command (default: bash)
exec "${@:-bash}"
