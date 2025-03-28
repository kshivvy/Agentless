from concurrent import futures
import uuid
import os
import threading
import time
import argparse
import logging
import sys

import google.api_core.exceptions
from google.cloud import pubsub_v1


# The GCP project ID.
_PROJECT_ID = "docker-rlef-exploration"

# The Pub/Sub topic IDs.
REQUEST_TOPIC_ID = "kshivvy-req"

# The Pub/Sub subscription IDs.
RESPONSE_SUBSCRIPTION_ID = "kshivvy-resp-sub"

# The dataset shard index.
SHARD_INDEX = -1

# The number of shards the dataset has been split into.
NUM_SHARDS = -1

# The session ID tag should be changed when launching mulitple
# python commands in parallel, such that requests/responses are
# routed correctly.
SESSION_ID = -1

class PubSubManager:
    def __init__(
            self,
            project_id: str = _PROJECT_ID,
            topic_id: str = REQUEST_TOPIC_ID,
            subscription_id: str = RESPONSE_SUBSCRIPTION_ID,
        ):
        # The GCP project ID, model request topic ID, and model response subscription ID.
        self.project_id = project_id
        self.topic_id = topic_id
        self.subscription_id = subscription_id

        self.waiter: dict[str, futures.Future[str]] = {}

        # Lock for accesing the waiter in a thread-safe manner.
        self.lock = threading.Lock()

        # The GCP publisher and subscriber clients.
        self.publisher = pubsub_v1.PublisherClient()
        self.subscriber = pubsub_v1.SubscriberClient()

        # A daemon thread to listen for responses and update the waiter.
        self.listener_thread = None

        # An event to signal the listener thread to stop.
        self.stop_event = threading.Event()

    def call_async(
        self, data_str: str, attributes: dict[str, str]
    ) -> futures.Future[str]:
        topic_path = self.publisher.topic_path(self.project_id, self.topic_id)
        result = futures.Future()

        data = data_str.encode("utf-8")
        attributes["request_id"] = request_id = str(uuid.uuid4())
        attributes["shard_index"] = str(SHARD_INDEX)
        attributes["num_shards"] = str(NUM_SHARDS)
        attributes["session_id"] = str(SESSION_ID)

        with self.lock:
            self.waiter[request_id] = result

        logging.debug(
            "Sending message [%s]: %s", request_id, data_str[:80].splitlines()[0]
        )
        publish_fut = self.publisher.publish(topic_path, data, **attributes)

        def callback(fut: futures.Future):
            if exc := fut.exception():
                self._set_exception(request_id, exc)

        publish_fut.add_done_callback(callback)

        return result

    def _set_result(self, request_id: str, result: str):
        with self.lock:
            if fut := self.waiter.pop(request_id, None):
                if not fut.done():
                    fut.set_result(result)

    def _set_exception(self, request_id: str, exc: BaseException):
        with self.lock:
            if fut := self.waiter.pop(request_id, None):
                if not fut.done():
                    fut.set_exception(exc)

    def listen(self):
        # The `subscription_path` method creates a fully qualified identifier
        # in the form `projects/{project_id}/subscriptions/{subscription_id}`

        if SESSION_ID == -1:
            subscription_path = self.subscriber.subscription_path(self.project_id, self.subscription_id)
            print(f"subscription_path: {subscription_path}")
        else:
            # Create a new subscription for this specific session ID. We assume this subscription
            # will be cleaned up on the server side.
            subscription_path = self.subscriber.subscription_path(
                self.project_id,
                f"{self.subscription_id}-sess-{SESSION_ID}"
            )
            topic_id_prefix = self.topic_id.removesuffix('-req')
            topic_path = self.publisher.topic_path(self.project_id, f"{topic_id_prefix}-resp")
            subscription_filter = f'attributes.shard_index = "{SHARD_INDEX}" AND attributes.session_id = "{SESSION_ID}"'
            subscription = pubsub_v1.types.Subscription(
                name=subscription_path,
                topic=topic_path,
                filter=subscription_filter,
            )
            try:
                self.subscriber.create_subscription(subscription)
                print(f"Created subscription {subscription_path}")
            except google.api_core.exceptions.AlreadyExists:
                print(f"Subscription {subscription_path} under topic {topic_path} already exists.")

        def callback(message):
            if request_id := message.attributes.get("request_id"):
                self._set_result(request_id, message.data.decode("utf-8"))
            message.ack()

        streaming_pull_future = self.subscriber.subscribe(
            subscription_path,
            callback=callback,
        )

        # Wrap subscriber in a with block to automatically call close() when done.
        with self.subscriber:
            try:
                self.stop_event.wait()
                print("Stopping listener thread...")
                streaming_pull_future.cancel()  # Trigger the shutdown.
                streaming_pull_future.result()  # Block until the shutdown is complete.
            except futures.TimeoutError:
                streaming_pull_future.cancel()  # Trigger the shutdown.
                streaming_pull_future.result()  # Block until the shutdown is complete.
            except Exception as e:
                print(f"Error in listen thread: {e}")

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
    logging.basicConfig(level=logging.DEBUG, stream=sys.stderr)

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
    PUB_SUB_MANAGER.start_listening()

    data_str = "What is the meaning of life?"
    attributes = {
        "kernel_id": "als:bard",
    }
    response = PUB_SUB_MANAGER.call_async(data_str, attributes).result()

    print(response)

    PUB_SUB_MANAGER.stop_listening()

if __name__ == "__main__":
    main()
