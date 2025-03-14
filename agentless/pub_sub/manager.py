from concurrent import futures
import uuid
import os
import threading
import time
import argparse

from google.cloud import pubsub_v1

# The GCP project ID.
_PROJECT_ID = "docker-rlef-exploration"

# The Pub/Sub topic IDs.
REQUEST_TOPIC_ID = "lamda-request"

# The Pub/Sub subscription IDs.
RESPONSE_SUBSCRIPTION_ID = "lamda-response-sub"

class PubSubManager:
    def __init__(
            self,
            project_id: str = _PROJECT_ID,
            topic_id: str = REQUEST_TOPIC_ID,
            subscription_id: str = RESPONSE_SUBSCRIPTION_ID
        ):
        # The GCP project ID, model request topic ID, and model response subscription ID.
        self.project_id = project_id
        self.topic_id = topic_id
        self.subscription_id = subscription_id

        # A local, in-memory cache for storing model respones.
        self.cache = {}
        
        # Lock for accesing the cache in a thread-safe manner.
        self.lock = threading.Lock()

        # The GCP publisher and subscriber clients.
        self.publisher = pubsub_v1.PublisherClient()
        self.subscriber = pubsub_v1.SubscriberClient()

        # A daemon thread to listen for responses and update the local cache.
        self.listener_thread = None

        # An event to signal the listener thread to stop.
        self.stop_event = threading.Event()

    def get_request_id(self) -> str:
        with self.lock:
            return str(uuid.uuid1())

    def publish(self, data_str: str, request_id: str, attributes: dict[str, str]) -> str:
        topic_path = self.publisher.topic_path(self.project_id, self.topic_id)

        data = data_str.encode("utf-8")

        # When you publish a message, the client returns a future.
        future = self.publisher.publish(topic_path, data, request_id=request_id, **attributes)
        return future.result()


    def listen(self):
        # The `subscription_path` method creates a fully qualified identifier
        # in the form `projects/{project_id}/subscriptions/{subscription_id}`
        subscription_path = self.subscriber.subscription_path(self.project_id, self.subscription_id)

        def callback(message):
            if self.stop_event.is_set():
                message.nack()
                return
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
                while not self.stop_event.is_set():
                    time.sleep(0.1)  # Check every 100ms
                print("Stopping listener thread...")
                streaming_pull_future.cancel()  # Trigger the shutdown.
                streaming_pull_future.result()  # Block until the shutdown is complete.
            except futures.TimeoutError:
                streaming_pull_future.cancel()  # Trigger the shutdown.
                streaming_pull_future.result()  # Block until the shutdown is complete.
            except Exception as e:
                print(f"Error in listen thread: {e}")

    def get(self, request_id: str) -> str:
        with self.lock:
            return self.cache.get(request_id, '')

    def evict(self, request_id: str) -> str:
        with self.lock:
            return self.cache.pop(request_id, None)

    def start_listening(self):
        if self.listener_thread is None or not self.listener_thread.is_alive():
            self.stop_event.clear()
            self.listener_thread = threading.Thread(target=self.listen, daemon=True)
            print("Starting listener thread...")
            self.listener_thread.start()

    def stop_listening(self):
        if self.listener_thread and self.listener_thread.is_alive():
            self.stop_event.set()
            self.listener_thread.join()
            print("Stopped listener thread...")
            self.listener_thread = None

# Public, reusable instance of the PubSubManager.
PUB_SUB_MANAGER = PubSubManager()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic_id", type=str, default=REQUEST_TOPIC_ID)
    parser.add_argument("--subscription_id", type=str, default=RESPONSE_SUBSCRIPTION_ID)
    args = parser.parse_args()

    # See https://cloud.google.com/docs/authentication/application-default-credentials#personal.
    # 1. Run gcloud auth application-default login
    # 2. Set the GOOGLE_APPLICATION_CREDENTIALS environment variable.
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = f"{os.path.expanduser('~')}/.config/gcloud/application_default_credentials.json"

    PUB_SUB_MANAGER.topic_id = args.topic_id
    PUB_SUB_MANAGER.subscription_id = args.subscription_id

    request_id = PUB_SUB_MANAGER.get_request_id()
    data_str = "What is the meaning of life?"
    attributes = {
        "kernel_id": "evergreen2://blade:gdm-aip-fastpath-agent-generate-service-prod/lmroot:v3_s_shared",
    }
    PUB_SUB_MANAGER.publish(data_str, request_id, attributes)
    PUB_SUB_MANAGER.start_listening()

    while True:
        response = PUB_SUB_MANAGER.get(request_id)
        if response:
            break
        time.sleep(0.1)

    response = PUB_SUB_MANAGER.get(request_id)
    PUB_SUB_MANAGER.evict(request_id)
    print(response)

    PUB_SUB_MANAGER.stop_listening()

if __name__ == "__main__":
    main()