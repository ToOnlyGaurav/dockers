from locust import HttpUser, task
from random import randrange
import json
import logging


class HelloWorldUser(HttpUser):
    services_count = 0
    services = []

    def on_start(self):
        response = self.client.get("/ranger/services/v1",
                                   headers={"Content-Type": "application/json"})

        logging.info("Log working..")
        logging.info(response.status_code)
        ranger_data = json.loads(response.text)
        self.services = ranger_data["data"]
        self.services_count = len(self.services)
        logging.info("Len: %d", self.services_count)
        logging.info(self.services)

    def getUrl(self):
        service = self.services[randrange(self.services_count)]
        return "/ranger/nodes/v1/phonepe/" + service["serviceName"]

    @task
    def func1(self):
        self.client.get("/ranger/nodes/v1/phonepe/outlander",
                        headers={"Content-Type": "application/json"})

    @task
    def func2(self):
        self.client.get(self.getUrl(),
                        headers={"Content-Type": "application/json"})
