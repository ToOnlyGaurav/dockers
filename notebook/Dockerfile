ARG PLATFORM=linux/amd64
FROM --platform=${PLATFORM} myubuntu-python
# FROM myubuntu-jammy

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Create a virtual environment and "activate" it by setting PATH
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    python -m pip install --no-cache-dir notebook jupyterlab ipykernel

# Create and switch to a non-root user
RUN useradd -m jupyteruser
USER jupyteruser

EXPOSE 8888

CMD ["jupyter", "notebook", "--ip=0.0.0.0", "--port=8888", "--no-browser"]
