from typing import TypedDict, NotRequired, Any


class Bug(TypedDict):
    """Individual data of https://huggingface.co/datasets/princeton-nlp/SWE-bench_Lite."""

    repo: str
    instance_id: str
    base_commit: str
    patch: str
    test_patch: str
    problem_statement: str
    hints_text: str
    version: str
    FAIL_TO_PASS: list[str]
    PASS_TO_PASS: list[str]
    environment_setup_commit: str


class Trajectory(TypedDict):
    class Usage(TypedDict):
        prompt_tokens: int
        completion_tokens: int

    prompt: NotRequired[str]
    response: NotRequired[str]
    usage: Usage


NO_USAGE: Trajectory.Usage = {"prompt_tokens": 0, "completion_tokens": 0}
DUMMY_TRAJ: Trajectory = {"response": "", "usage": NO_USAGE}

class Localization(TypedDict):
    instance_id: str
    found_files: list[str]
    additional_artifact_loc_file: list[str]
    file_traj: dict[str, Any]
    found_related_locs: Any
    additional_artifact_loc_related: Any
    related_loc_traj: Trajectory
    found_edit_locs: Any
    additional_artifact_loc_edit_location: Any
    edit_loc_traj: Trajectory
