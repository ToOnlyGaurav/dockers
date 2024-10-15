from locust import HttpUser, task


class HelloWorldUser(HttpUser):
  @task
  def message(self):
    self.client.get("/api/v1/hello",
                    headers={"Content-Type": "application/json"})
