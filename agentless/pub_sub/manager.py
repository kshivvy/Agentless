import asyncio
from concurrent import futures
import uuid
import os
import argparse
import threading

from google.cloud import pubsub_v1

# The GCP project ID.
_PROJECT_ID = "docker-rlef-exploration"

# The Pub/Sub topic IDs.
DEFAULT_TOPIC_ID = "jjong-request"

# The Pub/Sub subscription IDs.
DEFAULT_SUBSCRIPTION_ID = "jjong-response-sub"


class PubSubManager:
    def __init__(
        self,
        project_id: str = _PROJECT_ID,
        topic_id: str = DEFAULT_TOPIC_ID,
        subscription_id: str = DEFAULT_SUBSCRIPTION_ID,
        max_concurrent_request: int = 16
    ):
        # The GCP project ID, model request topic ID, and model response subscription ID.
        self._project_id = project_id
        self._topic_id = topic_id
        self._subscription_id = subscription_id
        self._publisher = pubsub_v1.PublisherClient()
        self._subscriber = pubsub_v1.SubscriberClient()
        self._listen_future = None
        self._lock = threading.Lock()
        self._stop_event = None
        self._waiters: dict[str, asyncio.Future] = {}
        self._rate_limiter = asyncio.Semaphore(max_concurrent_request)

    async def __aenter__(self):
        self._stop_event = asyncio.Event()
        self._listen_future = asyncio.get_running_loop().create_task(
            self.listen()
        )
        return self

    async def __aexit__(self, *exc_info):
        print('PubSubManager is terminating...')
        self._stop_event.set()
        await self._listen_future

    async def call_async(self, data_str: str, attributes: dict[str, str]):
        request_id = str(uuid.uuid4())
        loop = asyncio.get_running_loop()
        waiter = loop.create_future()
        with self._lock:
            self._waiters[request_id] = (loop, waiter)
        topic_path = self._publisher.topic_path(self._project_id, self._topic_id)

        data = data_str.encode("utf-8")

        async with self._rate_limiter:
            # When you publish a message, the client returns a future.
            self._publisher.publish(
                topic_path, data, request_id=request_id, **attributes
            )
            message = await waiter
            message.ack()
            return message.data.decode("utf-8")

    async def listen(self):
        # The `subscription_path` method creates a fully qualified identifier
        # in the form `projects/{project_id}/subscriptions/{subscription_id}`
        subscription_path = self._subscriber.subscription_path(
            self._project_id, self._subscription_id
        )

        def callback(message):
            if self._stop_event.is_set():
                message.ack()
                return
            request_id = message.attributes.get("request_id")
            with self._lock:
                loop, waiter = self._waiters.get(request_id, (None, None))
            if waiter:
                loop.call_soon_threadsafe(
                    waiter.set_result,
                    message
                )
            else:
                print(f'Waiter not found for {request_id!r}')
                message.ack()

        print(f'Start subscribing {subscription_path}')
        streaming_pull_future = self._subscriber.subscribe(
            subscription_path,
            callback=callback,
        )

        # Wrap subscriber in a with block to automatically call close() when done.
        with self._subscriber:
            try:
                await self._stop_event.wait()
                print(f'Canceling subscription for {subscription_path}')
                streaming_pull_future.cancel()  # Trigger the shutdown.
                streaming_pull_future.result()  # Block until the shutdown is complete.
            except futures.TimeoutError:
                streaming_pull_future.cancel()  # Trigger the shutdown.
                streaming_pull_future.result()  # Block until the shutdown is complete.
            except Exception as e:
                print(f"Error in listen thread: {e}")


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic_id", type=str, default=DEFAULT_TOPIC_ID)
    parser.add_argument("--subscription_id", type=str, default=DEFAULT_SUBSCRIPTION_ID)
    args = parser.parse_args()

    # See https://cloud.google.com/docs/authentication/application-default-credentials#personal.
    # 1. Run gcloud auth application-default login
    # 2. Set the GOOGLE_APPLICATION_CREDENTIALS environment variable.
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = (
        f"{os.path.expanduser('~')}/.config/gcloud/application_default_credentials.json"
    )

    async with PubSubManager(
        topic_id=args.topic_id,
        subscription_id=args.subscription_id
    ) as pub_sub_mgr:
        result = await pub_sub_mgr.call_async(
            "What is the meaning of life?",
            {
                "kernel_id": "evergreen2://blade:gdm-aip-fastpath-agent-generate-service-prod/lmroot:v3_s_shared",
            }
        )
        print(result)


if __name__ == "__main__":
    asyncio.run(main())
