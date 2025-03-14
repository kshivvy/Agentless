import asyncio
import argparse
import json
import logging
import os
import dataclasses
from collections.abc import Iterable
from concurrent import futures
from typing import Any

from datasets import load_dataset

from agentless import data_types
from agentless.fl.FL import LLMFL
from agentless.util import models
from agentless.util import tqdm_utils
from agentless.util.preprocess_data import (
    filter_none_python,
    filter_out_test_files,
    get_full_file_paths_and_classes_and_functions,
    show_project_structure,
)
from agentless.util.utils import load_json, load_jsonl
from agentless.pub_sub import manager
from get_repo_structure.get_repo_structure import (
    clone_repo,
    get_project_structure_from_scratch,
)

# SET THIS IF YOU WANT TO USE THE PREPROCESSED FILES
PROJECT_FILE_LOC = os.environ.get("PROJECT_FILE_LOC", None)


@dataclasses.dataclass
class Args:
    output_folder: str
    output_file: str = "loc_outputs.jsonl"
    start_file: str | None = None
    file_level: bool = False
    related_level: bool = False
    fine_grain_line_level: bool = False
    top_n: int = 3
    temperature: float = 0.0
    num_samples: int = 1
    compress: bool = False
    merge: bool = False
    add_space: bool = False
    no_line_number: bool = False
    sticky_scroll: bool = False
    context_window: int = 10
    target_id: str | None = None
    mock: bool = False
    parallelism: int | None = None
    model: str | None = None
    topic_id: str = manager.DEFAULT_TOPIC_ID
    subscription_id: str = manager.DEFAULT_SUBSCRIPTION_ID


def get_repo_structure(instance_id: str) -> dict[str, Any]:
    assert PROJECT_FILE_LOC is not None, "PROJECT_FILE_LOC env var not set."
    project_file = os.path.join(PROJECT_FILE_LOC, instance_id + ".json")
    return load_json(project_file)["structure"]


async def localize(args: Args, model: models.DecoderBase):
    async def localize_instance(
        bug: data_types.Bug,
        args: Args,
        swe_bench_data: list[data_types.Bug],
        start_file_locs: Any,
        model: models.DecoderBase,
        executor: futures.ThreadPoolExecutor,
    ) -> data_types.Localization:
        instance_id = bug["instance_id"]
        structure = get_repo_structure(instance_id)

        # logging.info(f"================ localize {instance_id} ================")

        bench_data = [x for x in swe_bench_data if x["instance_id"] == instance_id][0]
        problem_statement = bench_data["problem_statement"]
        filter_none_python(structure)
        # some basic filtering steps
        # filter out test files (unless its pytest)
        if not instance_id.startswith("pytest"):
            filter_out_test_files(structure)

        found_files = []
        found_related_locs = []
        found_edit_locs = []

        additional_artifact_loc_file = None
        additional_artifact_loc_related = None
        additional_artifact_loc_edit_location = None
        file_traj, related_loc_traj, edit_loc_traj = {}, {}, {}

        # file level localization
        if args.file_level:
            fl = LLMFL(
                instance_id,
                structure,
                problem_statement,
                model,
            )
            found_files, additional_artifact_loc_file, file_traj = await fl.localize(
                mock=args.mock
            )
        else:
            # assume start_file is provided
            for locs in start_file_locs:
                if locs["instance_id"] == instance_id:
                    found_files = locs["found_files"]
                    additional_artifact_loc_file = locs["additional_artifact_loc_file"]
                    file_traj = locs["file_traj"]

                    if "found_related_locs" in locs:
                        found_related_locs = locs["found_related_locs"]
                        additional_artifact_loc_related = locs[
                            "additional_artifact_loc_related"
                        ]
                        related_loc_traj = locs["related_loc_traj"]
                    break

        # related class, functions, global var localization
        if args.related_level:
            if len(found_files) != 0:
                pred_files = found_files[: args.top_n]
                fl = LLMFL(
                    instance_id,
                    structure,
                    problem_statement,
                    model,
                )

                additional_artifact_loc_related = []
                found_related_locs = []
                related_loc_traj = {}

                if args.compress:
                    (
                        found_related_locs,
                        additional_artifact_loc_related,
                        related_loc_traj,
                    ) = await fl.localize_function_from_compressed_files(
                        file_names=pred_files, mock=args.mock, executor=executor
                    )
                    additional_artifact_loc_related = [additional_artifact_loc_related]
                else:
                    assert False, "Not implemented yet."

        if args.fine_grain_line_level:
            # Only supports the following args for now

            pred_files = found_files[: args.top_n]
            fl = LLMFL(
                instance_id,
                structure,
                problem_statement,
                model,
            )
            coarse_found_locs = {}
            for i, pred_file in enumerate(pred_files):
                if len(found_related_locs) > i:
                    coarse_found_locs[pred_file] = found_related_locs[i]
            (
                found_edit_locs,
                additional_artifact_loc_edit_location,
                edit_loc_traj,
            ) = await fl.localize_line_from_coarse_function_locs(
                file_names=pred_files,
                coarse_locs=coarse_found_locs,
                context_window=args.context_window,
                add_space=args.add_space,
                no_line_number=args.no_line_number,
                sticky_scroll=args.sticky_scroll,
                mock=args.mock,
                temperature=args.temperature,
                num_samples=args.num_samples,
                executor=executor,
            )

            additional_artifact_loc_edit_location = [
                additional_artifact_loc_edit_location
            ]

        return {
            "instance_id": instance_id,
            "found_files": found_files,
            "additional_artifact_loc_file": additional_artifact_loc_file,
            "file_traj": file_traj,
            "found_related_locs": found_related_locs,
            "additional_artifact_loc_related": additional_artifact_loc_related,
            "related_loc_traj": related_loc_traj,
            "found_edit_locs": found_edit_locs,
            "additional_artifact_loc_edit_location": additional_artifact_loc_edit_location,
            "edit_loc_traj": edit_loc_traj,
        }

    swe_bench_data: Iterable[data_types.Bug] = load_dataset(
        "princeton-nlp/SWE-bench_Lite", split="test"
    )
    start_file_locs = load_jsonl(args.start_file) if args.start_file else None
    with futures.ThreadPoolExecutor(max_workers=args.parallelism) as executor:
        locs = [
            localize_instance(
                bug=bug,
                args=args,
                swe_bench_data=swe_bench_data,
                start_file_locs=start_file_locs,
                model=model,
                executor=executor,
            )
            for bug in swe_bench_data
        ]
        async for loc in tqdm_utils.as_completed(locs, total=len(locs)):
            with open(args.output_file, "a") as f:
                f.write(json.dumps(loc) + "\n")


def merge(args):
    """Merge predicted locations."""
    start_file_locs = load_jsonl(args.start_file)
    # Dump each location sample.
    for st_id in [0, 1, 2, 3]:
        en_id = st_id
        merged_locs = []
        for locs in start_file_locs:
            merged_found_locs = []
            if "found_locs" in locs and len(locs["found_locs"]):
                merged_found_locs = ["\n".join(x) for x in locs["found_locs"][st_id]]
            merged_locs.append({**locs, "found_locs": merged_found_locs})
        with open(
            f"{args.output_folder}/locs_merged_{st_id}-{en_id}_outputs.jsonl", "w"
        ) as f:
            for data in merged_locs:
                f.write(json.dumps(data) + "\n")

    ### Merge each 2.
    for st_id in [0, 2]:
        en_id = st_id + 1
        merged_locs = []
        for locs in start_file_locs:
            merged_found_locs = []
            if "found_locs" in locs and len(locs["found_locs"]):
                merged_found_locs = ["\n".join(x) for x in locs["found_locs"][st_id]]
                for sample_found_locs in locs["found_locs"][st_id + 1 : en_id + 1]:
                    for i, file_found_locs in enumerate(sample_found_locs):
                        if isinstance(file_found_locs, str):
                            merged_found_locs[i] += "\n" + file_found_locs
                        else:
                            merged_found_locs[i] += "\n" + "\n".join(file_found_locs)
            merged_locs.append({**locs, "found_locs": merged_found_locs})
        with open(
            f"{args.output_folder}/locs_merged_{st_id}-{en_id}_outputs.jsonl", "w"
        ) as f:
            for data in merged_locs:
                f.write(json.dumps(data) + "\n")

    ### Merge all 4.
    all_4_merged_locs = []
    for locs in start_file_locs:
        merged_found_locs = []
        if "found_locs" in locs and len(locs["found_locs"]):
            merged_found_locs = ["\n".join(x) for x in locs["found_locs"][0]]
            for sample_found_locs in locs["found_locs"][1:]:
                for i, file_found_locs in enumerate(sample_found_locs):
                    if isinstance(file_found_locs, str):
                        merged_found_locs[i] += "\n" + file_found_locs
                    else:
                        merged_found_locs[i] += "\n" + "\n".join(file_found_locs)
        all_4_merged_locs.append({**locs, "found_locs": merged_found_locs})
    with open(f"{args.output_folder}/locs_merged4_outputs.jsonl", "w") as f:
        for data in all_4_merged_locs:
            f.write(json.dumps(data) + "\n")


async def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("--output_folder", type=str, required=True)
    parser.add_argument("--output_file", type=str, default="loc_outputs.jsonl")
    parser.add_argument(
        "--start_file",
        type=str,
        help="""previous output file to start with to reduce
        the work, should use in combination without --file_level""",
    )
    parser.add_argument("--file_level", action="store_true")
    parser.add_argument("--related_level", action="store_true")
    parser.add_argument("--fine_grain_line_level", action="store_true")
    parser.add_argument("--top_n", type=int, default=3)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--num_samples", type=int, default=1)
    parser.add_argument("--compress", action="store_true")
    parser.add_argument("--merge", action="store_true")
    parser.add_argument("--add_space", action="store_true")
    parser.add_argument("--no_line_number", action="store_true")
    parser.add_argument("--sticky_scroll", action="store_true")
    parser.add_argument("--context_window", type=int, default=10)
    parser.add_argument("--target_id", type=str)
    parser.add_argument(
        "--mock", action="store_true", help="Mock run to compute prompt tokens."
    )
    parser.add_argument("--parallelism", type=int, default=16)
    parser.add_argument("--model", type=str, default=None)
    parser.add_argument("--topic_id", type=str, default=manager.DEFAULT_TOPIC_ID)
    parser.add_argument(
        "--subscription_id", type=str, default=manager.DEFAULT_SUBSCRIPTION_ID
    )

    args = parser.parse_args()

    import os

    args.output_file = os.path.join(args.output_folder, args.output_file)

    assert not os.path.exists(args.output_file), "Output file already exists"

    assert not (
        args.file_level and args.start_file
    ), "Cannot use both file_level and start_file"

    assert not (
        args.file_level and args.fine_grain_line_level and not args.related_level
    ), "Cannot use both file_level and fine_grain_line_level without related_level"

    assert not (
        (not args.file_level) and (not args.start_file)
    ), "Must use either file_level or start_file"

    os.makedirs(args.output_folder, exist_ok=True)

    # write the arguments
    with open(f"{args.output_folder}/args.json", "w") as f:
        json.dump(vars(args), f, indent=4)

    logging.basicConfig(
        filename=f"{args.output_folder}/localize.log",
        level=logging.DEBUG,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )
    async with manager.PubSubManager(
        topic_id=args.topic_id,
        subscription_id=args.subscription_id,
        max_concurrent_request=args.parallelism,
    ) as pub_sub_mgr:
        model = models.PubSubDecoder(name=args.model, pub_sub_mgr=pub_sub_mgr)

        if args.merge:
            merge(args)
        else:
            await localize(args, model)


if __name__ == "__main__":
    asyncio.run(main(), debug=True)
