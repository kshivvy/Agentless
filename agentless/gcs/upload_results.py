import argparse
import os
import tqdm

from google.cloud import storage
from google.cloud.storage import transfer_manager

_BUCKET_NAME = "agentless-results"


def bulk_upload(bucket_name, source_dir, dest_dir, workers):
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)

    filenames = []
    for root, _, files in os.walk(source_dir):
        for filename in files:
            file_path = os.path.join(root, filename)
            relative_path = os.path.relpath(file_path, source_dir)
            filenames.append(relative_path)

    results = transfer_manager.upload_many_from_filenames(
        bucket,
        filenames,
        source_dir,
        blob_name_prefix=dest_dir,
        max_workers=workers,
        skip_if_exists=False,
    )

    for name, result in zip(filenames, results):
        # The results list is either `None` or an exception for each filename in
        # the input list, in order.
        if isinstance(result, Exception):
            print("Failed to upload {} due to exception: {}".format(name, result))
        else:
            print("Uploaded {} to {}.".format(name, bucket.name))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bucket_name", type=str, default=_BUCKET_NAME, help="GCS bucket name"
    )
    parser.add_argument(
        "--source_dir", type=str, required=True, help="Local directory to upload"
    )
    parser.add_argument(
        "--dest_dir", type=str, required=True, help="GCS directory to upload to"
    )
    parser.add_argument(
        "--num_workers", type=int, default=8, help="Number of workers to use for upload"
    )
    args = parser.parse_args()

    bulk_upload(
        args.bucket_name,
        args.source_dir,
        # Always make the dest_dir ends with "/"
        os.path.join(args.dest_dir, ""),
        args.num_workers,
    )


if __name__ == "__main__":
    main()
