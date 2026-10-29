"""Run build.sh against stub commands to check when it retries buildctl.

Run: python -m pytest packages/infrastructure/wf_dockerfile_build/tests
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "build.sh"

RST_STREAM = (
    "error: failed to receive status: rpc error: code = Internal desc = "
    "stream terminated by RST_STREAM with error code: INTERNAL_ERROR"
)
SOLVE_ERROR = 'error: failed to solve: process "/bin/sh -c pnpm build" did not complete successfully: exit code: 1'


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(f"#!/usr/bin/env bash\n{body}\n")
    path.chmod(0o755)


def _run(tmp_path: Path, buildctl_outputs: list[tuple[int, str]], available: str = "1", epoch_step: int = 0):
    """Run build.sh; buildctl call N exits and prints buildctl_outputs[N] (the last entry repeats)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "log"
    log.touch()
    (tmp_path / "repo").mkdir()
    (tmp_path / "tag").write_text("abc123")
    # The image's fixed paths can't exist on a test machine.
    script = tmp_path / "build.sh"
    text = SCRIPT.read_text()
    for real, fake in {
        "/code/repo": tmp_path / "repo",
        "/.docker/config.json": tmp_path / "config.json",
        "/tmp/tag": tmp_path / "tag",
        "/tmp/exists": tmp_path / "exists",
    }.items():
        text = text.replace(real, str(fake))
    script.write_text(text)
    script.chmod(0o755)

    outputs = tmp_path / "outputs"
    outputs.mkdir()
    for i, (code, message) in enumerate(buildctl_outputs):
        (outputs / f"{i}.code").write_text(str(code))
        (outputs / f"{i}.msg").write_text(message)
    last = len(buildctl_outputs) - 1

    _stub(bin_dir, "pf-buildkit-validate", 'BUILDKIT_STATEFULSET_NAME_PREFIX="buildkit-"\nBUILDKIT_NAMESPACE="buildkit"')
    _stub(bin_dir, "aws", 'if [[ $2 == "describe-images" ]]; then exit 1; fi\necho password')
    _stub(
        bin_dir,
        "pf-buildkit-get-address",
        f'n=$(grep -c "^get-address" {log}); echo "get-address $*" >> {log}; echo "tcp://host-$n:1234"',
    )
    _stub(bin_dir, "pf-buildkit-record-build", f'echo "record-build $*" >> {log}')
    _stub(bin_dir, "kubectl", f'echo "kubectl $*" >> {log}; echo {available}')
    _stub(bin_dir, "sleep", f'echo "sleep $*" >> {log}')
    _stub(bin_dir, "date", f'n=$(grep -c "^sleep" {log}); echo $((1000 + n * {epoch_step}))')
    _stub(
        bin_dir,
        "buildctl",
        f'n=$(grep -c "^buildctl" {log}); echo "buildctl $BUILDKIT_HOST" >> {log}\n'
        f"[[ $n -gt {last} ]] && n={last}\n"
        f'cat {outputs}/$n.msg >&2; exit $(cat {outputs}/$n.code)',
    )

    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "ARCH": "amd64",
        "USE_ARCH_SUFFIX": "1",
        "IMAGE_REPO": "repo",
        "IMAGE_REGION": "us-west-2",
        "IMAGE_REGISTRY": "registry",
        "PUSH_IMAGE": "true",
        "BUILD_CONTEXT": ".",
        "DOCKERFILE_PATH": "Dockerfile",
        "BUILDKIT_BUCKET_REGION": "us-west-2",
        "BUILDKIT_BUCKET_NAME": "bucket",
    }
    result = subprocess.run([str(script)], env=env, capture_output=True, text=True, cwd=tmp_path)
    return result, log.read_text().splitlines()


def _calls(lines: list[str], prefix: str) -> list[str]:
    return [line for line in lines if line.startswith(prefix)]


def test_builds_once_when_buildctl_succeeds(tmp_path):
    result, lines = _run(tmp_path, [(0, "")])
    assert result.returncode == 0, result.stderr
    assert _calls(lines, "buildctl") == ["buildctl tcp://host-0:1234"]
    assert _calls(lines, "sleep") == []


def test_retries_on_a_new_address_after_buildkitd_drops_the_connection(tmp_path):
    result, lines = _run(tmp_path, [(1, RST_STREAM), (0, "")])
    assert result.returncode == 0, result.stderr
    assert _calls(lines, "buildctl") == ["buildctl tcp://host-0:1234", "buildctl tcp://host-1:1234"]
    # Waits for a ready replica before asking for an address again.
    retry = lines.index("buildctl tcp://host-0:1234")
    assert any(line.startswith("kubectl get statefulset buildkit-amd64") for line in lines[retry:])
    assert len(_calls(lines, "record-build")) == 2


def test_does_not_retry_a_dockerfile_failure(tmp_path):
    result, lines = _run(tmp_path, [(1, SOLVE_ERROR), (0, "")])
    assert result.returncode != 0
    assert len(_calls(lines, "buildctl")) == 1


def test_does_not_retry_when_a_build_step_merely_prints_a_connection_error(tmp_path):
    output = "#12 0.5 curl: (7) Failed to connect: Connection refused RST_STREAM\n" + SOLVE_ERROR
    result, lines = _run(tmp_path, [(1, output), (0, "")])
    assert result.returncode != 0
    assert len(_calls(lines, "buildctl")) == 1


def test_gives_up_after_three_attempts(tmp_path):
    result, lines = _run(tmp_path, [(1, RST_STREAM)])
    assert result.returncode != 0
    assert len(_calls(lines, "buildctl")) == 3


def test_fails_when_no_buildkitd_becomes_ready(tmp_path):
    result, lines = _run(tmp_path, [(1, RST_STREAM), (0, "")], available="0", epoch_step=60)
    assert result.returncode != 0
    assert len(_calls(lines, "buildctl")) == 1
    assert "Timeout" in result.stderr
