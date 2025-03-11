from concurrent import futures
import uuid
import json

import os
import threading

from google.cloud import pubsub_v1

# The GCP project ID.
_PROJECT_ID = "docker-rlef-exploration"

# The Pub/Sub topic IDs.
_REQUEST_TOPIC_ID = "lamda-request"
_RESPONSE_TOPIC_ID = "lamda-response"

# The Pub/Sub subscription IDs.
_RESPONSE_SUBSCRIPTION_ID = "lamda-response-sub"
_REQUEST_SUBSCRIPTION_ID = "lamda-request-sub"

class PubSubManager:
    def __init__(self, project_id: str = _PROJECT_ID):
        # The GCP project ID.
        self.project_id = project_id

        # A local, in-memory cache for storing model respones.
        self.cache = {}
        
        # Lock for accesing the cache in a thread-safe manner.
        self.lock = threading.Lock()

        # The GCP publisher and subscriber clients.
        self.publisher = pubsub_v1.PublisherClient()
        self.subscriber = pubsub_v1.SubscriberClient()

    def get_request_id(self) -> str:
        with self.lock:
            return str(uuid.uuid1())

    def publish(self, data_str: str, request_id: str, kernel_id: str | None = None, topic_id: str = _REQUEST_TOPIC_ID) -> str:
        topic_path = self.publisher.topic_path(self.project_id, topic_id)

        if not kernel_id:
            kernel_id = self.get_request()

        data = data_str.encode("utf-8")

        # When you publish a message, the client returns a future.
        future = self.publisher.publish(topic_path, data, request_id=request_id, kernel_id=kernel_id)
        return future.result()


    def listen(self, subscription_id: str = _RESPONSE_SUBSCRIPTION_ID):

        # The `subscription_path` method creates a fully qualified identifier
        # in the form `projects/{project_id}/subscriptions/{subscription_id}`
        subscription_path = self.subscriber.subscription_path(_PROJECT_ID, subscription_id)

        def callback(message):
            request_id = message.attributes.get("request_id")
            if request_id:
                with self.lock:
                    # message.data is a bytestring, so decode it.
                    self.cache[request_id] = message.data.decode("utf-8")
            message.ack()

        streaming_pull_future = self.subscriber.subscribe(
            subscription_path,
            callback=callback,
        )

        # Wrap subscriber in a with block to automatically call close() when done.
        with self.subscriber:
            try:
                # When `timeout` is not set, result() will block indefinitely,
                # unless an exception is encountered first.
                streaming_pull_future.result()
            except futures.TimeoutError:
                streaming_pull_future.cancel()  # Trigger the shutdown.
                streaming_pull_future.result()  # Block until the shutdown is complete.


    def get(self, request_id: str) -> str:
        with self.lock:
            return self.cache.get(request_id, '')


def main():
    # See https://cloud.google.com/docs/authentication/application-default-credentials#personal.
    # 1. Run gcloud auth application-default login
    # 2. Set the GOOGLE_APPLICATION_CREDENTIALS environment variable.
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = f"{os.path.expanduser('~')}/.config/gcloud/application_default_credentials.json"

    pub_sub_manager = PubSubManager()

    thread = threading.Thread(target=pub_sub_manager.listen)
    thread.start()

    request_id = pub_sub_manager.get_request_id()
    data_str = "What is the meaning of life?"
    kernel_id = 'als:bard'
    pub_sub_manager.publish(data_str, request_id, kernel_id)

    while True:
        response = pub_sub_manager.get(request_id)
        if response:
            break

    response = pub_sub_manager.get(request_id)
    print(response)

if __name__ == "__main__":
    main()
