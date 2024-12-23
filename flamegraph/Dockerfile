# Use the official Ubuntu base image
FROM myubuntu_python

COPY binaries /remote

ENV FLAME_HOME=/remote/FlameGraph

ENV PATH="$FLAME_HOME/bin:$PATH"

# Set the working directory
WORKDIR $FLAME_HOME
CMD ["bash"]