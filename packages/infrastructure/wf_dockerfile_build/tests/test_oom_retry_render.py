"""Guard the OOM retry in Implentio's wf_dockerfile_build, which static review can miss.

Run: python -m pytest packages/infrastructure/wf_dockerfile_build/tests
"""

from __future__ import annotations

import re
from pathlib import Path

MODULE_DIR = Path(__file__).resolve().parents[1]
MAIN_TF = MODULE_DIR / "main.tf"
VARS_TF = MODULE_DIR / "vars.tf"


def _main() -> str:
    return MAIN_TF.read_text()


def _expression() -> str:
    match = re.search(r'expression = "([^"]+)"', _main())
    assert match is not None, "the retry expression is missing"
    return match.group(1)


def test_retry_expression_does_not_read_exit_code():
    # Argo sets lastRetry.exitCode only for a container named `main`; a containerSet
    # pod has none, so it is always '-1' and an exit-code check never matches.
    assert "exitCode" not in _expression()


def test_retry_expression_covers_oom_and_spot_eviction():
    value = _expression()
    assert "lastRetry.message startsWith 'OOMKilled'" in value
    assert "lastRetry.message matches 'pod deleted'" in value


def test_ladder_casts_the_attempt_counter():
    # Argo exposes `retries` as a string; without this cast, pod patching fails.
    assert "sprig.int(retries) == ${attempt}" in _main()


def test_patch_names_only_the_buildctl_containers():
    # Pod requests add up across containers, so raising setup or clone wastes memory.
    text = _main()
    start = text.index("build_container_names = concat(")
    block = text[start : text.index(")\n", start)]
    assert re.findall(r'"([a-z0-9-]+)"', block) == ["build-amd64", "build-arm64"]


def test_request_and_limit_share_one_memory_expression():
    # Unequal values let the scheduler reserve less memory than the attempt needs.
    text = _main()
    start = text.index("oom_pod_spec_patch = ")
    block = text[start : text.index("\n  })", start)]
    memory_lines = re.findall(r"memory\s*=\s*(\S+)", block)
    assert memory_lines == ["local.oom_retry_memory_expression"] * 2


def test_ladder_changes_memory_only():
    text = _main()
    start = text.index("oom_pod_spec_patch = ")
    block = text[start : text.index("\n  })", start)]
    limits = block[block.index("limits = {") :]
    assert "cpu" not in limits


def test_oom_retry_is_on_by_default():
    text = VARS_TF.read_text()
    block = re.search(
        r'variable "oom_retry" \{.*?\n  default = (?P<default>\S+)', text, re.S
    )
    assert block is not None, "the oom_retry variable block is gone or reshaped"
    assert block.group("default") == "{}"
