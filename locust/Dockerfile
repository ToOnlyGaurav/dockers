FROM myubuntu-python

# Install locust (aerospike is already in the base image)
RUN pip install locust

COPY locustfiles /locustfiles
COPY entrypoint.sh /

WORKDIR /locustfiles

EXPOSE 8089

ENTRYPOINT ["/entrypoint.sh"]

CMD ["locust", "-f", "/locustfiles/aerospike_locustfile.py"]
