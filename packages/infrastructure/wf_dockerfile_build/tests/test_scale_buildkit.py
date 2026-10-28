"""Run scale-buildkit.sh against stub commands to check how it waits for buildkitd.

Run: python -m pytest packages/infrastructure/wf_dockerfile_build/tests
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "scale-buildkit.sh"


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(f"#!/usr/bin/env bash\n{body}\n")
    path.chmod(0o755)


def _run(tmp_path: Path, args: list[str], ready_after: int = 0, epoch_step: int = 0):
    """Run the script; kubectl reports 0 available replicas for the first `ready_after` calls."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "log"
    # The image has pf-buildkit-scale-up at /bin, which a test cannot stub.
    script = tmp_path / "scale-buildkit.sh"
    script.write_text(SCRIPT.read_text().replace("/bin/pf-buildkit-scale-up", "pf-buildkit-scale-up"))
    script.chmod(0o755)

    _stub(bin_dir, "pf-buildkit-validate", 'BUILDKIT_STATEFULSET_NAME_PREFIX="buildkit-"\nBUILDKIT_NAMESPACE="buildkit"')
    _stub(bin_dir, "pf-buildkit-scale-up", f'echo "scale-up $*" >> {log}')
    _stub(bin_dir, "sleep", f'echo "sleep $*" >> {log}')
    _stub(
        bin_dir,
        "kubectl",
        f'echo "kubectl $*" >> {log}\n'
        f'n=$(grep -c "^kubectl" {log})\n'
        f'if [[ $n -gt {ready_after} ]]; then echo 1; else echo 0; fi',
    )
    _stub(
        bin_dir,
        "date",
        f'n=$(grep -c "^sleep" {log} 2>/dev/null || true)\necho $((1000 + n * {epoch_step}))',
    )

    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
    result = subprocess.run([str(script), *args], env=env, capture_output=True, text=True, cwd=tmp_path)
    lines = log.read_text().splitlines() if log.exists() else []
    return result, lines


def test_scale_up_runs_without_its_10s_wait(tmp_path):
    result, lines = _run(tmp_path, ["--only=amd64", "--wait"])
    assert result.returncode == 0, result.stderr
    assert lines[0] == "scale-up --only=amd64"


def test_polls_every_2s_until_a_replica_is_available(tmp_path):
    result, lines = _run(tmp_path, ["--only=arm64", "--wait"], ready_after=3)
    assert result.returncode == 0, result.stderr
    assert [line for line in lines if line.startswith("sleep")] == ["sleep 2"] * 3
    assert all("statefulset buildkit-arm64" in line for line in lines if line.startswith("kubectl"))


def test_waits_for_both_arches_without_only(tmp_path):
    result, lines = _run(tmp_path, ["--wait"])
    assert result.returncode == 0, result.stderr
    assert lines[0] == "scale-up "
    kubectl = [line for line in lines if line.startswith("kubectl")]
    assert any("buildkit-arm64" in line for line in kubectl)
    assert any("buildkit-amd64" in line for line in kubectl)


def test_does_not_wait_without_the_wait_flag(tmp_path):
    result, lines = _run(tmp_path, ["--only=amd64"], ready_after=100)
    assert result.returncode == 0, result.stderr
    assert lines == ["scale-up --only=amd64"]


def test_fails_after_10_minutes(tmp_path):
    result, _ = _run(tmp_path, ["--only=amd64", "--wait"], ready_after=10_000, epoch_step=60)
    assert result.returncode == 1
    assert "Timeout" in result.stderr

