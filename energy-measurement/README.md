# Energy measurement instrumentation

## Purpose

This directory is not part of the upstream torchvision repository. It was added
to measure the energy consumption of CI/CD pipeline commands on controlled
hardware, using Intel RAPL counters, at release `v0.17.0`. Branch
`release-0.17.0` is the tag commit `b2383d44751bf85e58cfb9223bbf4e5961c09fa1` plus one commit
adding these files; the composition, the literal commands of the stages and the
pipeline logic are those of the measurement of this fork's default branch, and
only what the tag requires differs. The measured construct is the energy of
the CI commands on a controlled bench, not the energy of GitHub-hosted CI in
production.

## Non-invasiveness

No original project file is created or modified. The only additions are this
directory and `.github/workflows/energy-measurement.yml`. Verify with:

```bash
git remote add upstream https://github.com/pytorch/vision.git
git fetch upstream tag v0.17.0
git diff --name-only v0.17.0 HEAD
```

## What is measured

Energy is read from the Intel RAPL counters under
`/sys/class/powercap/intel-rapl`, for four domains: package (`pkg`), cores,
uncore (reported as `gpu`, structurally zero on this bench) and DRAM (`ram`).
Counter deltas are overflow-corrected against `max_energy_range_uj`, read from
sysfs at run time rather than hardcoded.

Each run measures a 120 s idle baseline first and derives a per-second rate per
domain. Reported energy per stage is

```
net = max(raw_delta - baseline_rate * wall_time_s, 0)
```

The clamp at zero prevents a negative DRAM figure on light memory workloads;
the unclamped DRAM value is kept as the diagnostic column
`energy_ram_liquid_raw_j`.

`wall_time_s` covers the whole `docker run --rm` lifecycle, including container
setup and teardown, because the RAPL reading window covers the same interval.
`wall_time_container_s` is measured inside the container; the difference
isolates container overhead.

Per-stage CPU time is captured inside the container: file descriptor 3
preserves the workload's stderr while `time` writes to `/timing`, so the CPU
time of child processes is attributed to the stage.

Host paging is recorded per stage (`swap_in_pages`, `swap_out_pages`) from
`/proc/vmstat`. Each stage also writes `temp_run_NN_<stage>.txt`, the package
temperature from the `coretemp` hwmon sensor labelled `Package id 0`, read on
the host immediately before and after the RAPL window, never inside it.

## How to run

```bash
# from a clone of this branch; prebake/ holds the HTTPS stub, its entrypoint and the giflib sample GIFs
docker build -t torchvision-measurement-0.17.0 -f energy-measurement/Dockerfile \
    --build-context prebake=<prebake directory> .
bash energy-measurement/run_pipeline.sh 1
```

The workflow runs the same script on a self-hosted runner, dispatched manually:

```bash
gh workflow run energy-measurement.yml -f campaign=validation   # run 0 only
gh workflow run energy-measurement.yml -f campaign=full         # warm-up + 10 runs
```

## Stages

torchvision is an inference-only project here: the pipeline has no training
stage. Each stage runs in its own container.

| stage | corresponds to | command |
|---|---|---|
| `build` | the conda environment setup and package install of `unittest.sh`/`setup-env.sh` | offline install of `setuptools`, `av`, `torch`, the requirements extracted by `setup.py egg_info`, the project itself (`setup.py develop`) and the test utilities |
| `test` | `python test/smoke_test.py` followed by the `pytest` invocation of `unittest.sh` | smoke test, then the suite split into four static blocks (see below) |

Reference cell: `tests.yml`, job `unittests-linux`, CPU / Python 3.10, at tag
`v0.17.0` (cell 1 of 15).

## Deviations from the upstream pipeline

- **Test suite partitioned into four static blocks.** The upstream job runs one
  `pytest` invocation; here it is split into `test_models.py -k
  test_classification_model`, `test_models.py -k "not
  test_classification_model"`, the remainder without the class
  `TestFxFeatureExtraction`, and that class alone. The remainder is the whole
  suite minus `test_models.py`, because the upstream invocation has no
  exclusion at this tag (video and ONNX tests included). The split is imposed
  by the bench's memory limit: the class alone takes most of the 14 GiB of the
  container and, inside the remainder, the process exceeds it. It is **static
  and deterministic** (file path, class and function name, no dynamic
  sharding), and coverage is checked by `--collect-only` to equal the original
  suite at this tag (38417 ids). The stage exit code is that of the first
  block that fails.
- **Offline dependencies and pre-baked weights.** Everything is built into the
  image and installed with `--no-index`. RAPL has no network domain.
- **Local HTTPS stub** for `sourceforge.net` and `drive.google.com`, mapped to
  loopback with `--add-host`, because a small number of tests dereference those
  hosts. The stub serves the same bytes, verified by sha256 against a manifest.
  At this tag only the Google Drive redirect test dereferences the stub; the
  GIF samples are served but no test requests them.
- **`GITHUB_ACTIONS=true`.** The upstream job runs on GitHub Actions and the
  suite branches on this variable; setting it is a fidelity correction, not an
  addition.
- **Stable torch 2.2.0** from the CPU index instead of the release-candidate
  channel (`whl/test`) that `setup-env.sh` selects on release branches, so the
  measurement is reproducible against a fixed artifact. The candidate served on
  the tag date has the same sha256 as the final wheel, which is the version
  `torchvision 0.17.0` requires.
- **Dependency versions fixed at the tag date.** The tag pins no versions and
  the logs of its CI run are no longer available; Miniconda, the conda packages
  of the environment and every unpinned Python package are the newest releases
  at the tag commit (2024-01-29T14:10:29Z).
- **`av` 11.0.0 wheel rebuilt.** The newest PyAV at the tag date (11.0.0) is
  published as source only today. The image rebuilds its wheel as upstream
  built it (manylinux2014 image of the time, the FFmpeg 6.0 build of
  `pyav-ffmpeg` 6.0.0-1, `auditwheel repair`), outside the measured window, and
  the measured `build` installs it offline like every other dependency. The
  environment keeps the `ffmpeg` 4.2.2 that `setup-env.sh` installs.
- **Expected exit 1 of `test`.** `TestVideoApi::test_keyframe_reading` compares
  the key frames PyAV reports with those of the torchvision video reader, built
  against the environment's `ffmpeg` 4.2.2; its four cases differ in every run.
  They are measured as they are and declared.
- **Stale build products removed from the image.** `setup.py develop` builds
  in place; the image drops `build/` and backdates the extension modules so the
  measured `build` compiles from scratch, as on a fresh CI checkout.
- **Memory limit of 14 GiB** with `--memory-swap` equal to it, so
  `memory.swap.max` is zero and the container cannot page, as in the
  measurement of the default branch.

## Output schema

One CSV per run, one row per stage plus a `total` row:

```
run, stage, energy_pkg_j, energy_cores_j, energy_gpu_j, energy_ram_j,
wall_time_s, user_time_s, sys_time_s, energy_ram_liquid_raw_j,
wall_time_container_s, swap_in_pages, swap_out_pages
```

The first nine columns are the official schema shared by every project in the
study; the last four are diagnostic. Exit codes are written to a sidecar
`exit_codes_run_NN.txt`, the package temperature to `temp_run_NN_<stage>.txt`,
and the actual execution order to `execution_order.txt`.

## Reproducibility notes

Bench: Intel Core i7-9700 (8 cores, no SMT), 16 GB RAM, Crucial BX500 SATA SSD,
Ubuntu 24.04 LTS, kernel 6.8.0, Docker 29.x.

Container flags: `--rm --privileged --network none --memory=14g
--memory-swap=14g`, plus the two `--add-host` entries for the HTTPS stub.

The upstream runner has 48 vCPUs against 8 on this bench; thread counts are
inherited from the upstream commands and are not overridden.
