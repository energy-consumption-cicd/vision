# Energy measurement instrumentation

## Purpose

This directory is not part of the upstream torchvision repository. It was added
to measure the energy consumption of CI/CD pipeline commands on controlled
hardware, using Intel RAPL counters, at release `v0.25.0`. Branch
`release-0.25.0` is the tag commit `8ac84ee75afb1c327902156b5336f56ad63b7e2f` plus one commit
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
git fetch upstream tag v0.25.0
git diff --name-only v0.25.0 HEAD
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
docker build -t torchvision-measurement-0.25.0 -f energy-measurement/Dockerfile \
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
| `build` | the conda environment setup and package install of `unittest.sh`/`setup-env.sh` | offline install of `setuptools`, `av`, `torch`, the project itself (editable), the extra decoders and the test utilities |
| `test` | `python test/smoke_test.py` followed by the `pytest` invocation of `unittest.sh` | smoke test, then the suite split into three static blocks (see below) |

Reference cell: `tests.yml`, job `unittests-linux`, CPU / Python 3.10, at tag
`v0.25.0` (cell 1 of 9).

## Deviations from the upstream pipeline

- **Test suite partitioned into three static blocks.** The upstream job runs one
  `pytest` invocation; here it is split into `test_models.py -k
  test_classification_model`, `test_models.py -k "not
  test_classification_model"`, and the remainder. The split is imposed by the
  bench's memory limit, is **static and deterministic** (file path and function
  name, no dynamic sharding), and coverage is checked by `--collect-only` to
  equal the original suite at this tag. The stage exit code is the aggregate of
  the three.
- **Offline dependencies and pre-baked weights.** Everything is built into the
  image and installed with `--no-index`. RAPL has no network domain.
- **Local HTTPS stub** for `sourceforge.net` and `drive.google.com`, mapped to
  loopback with `--add-host`, because a small number of tests dereference those
  hosts. The stub serves the same bytes, verified by sha256 against a manifest.
- **`GITHUB_ACTIONS=true`.** The upstream job runs on GitHub Actions and the
  suite branches on this variable; setting it is a fidelity correction, not an
  addition.
- **Stable torch 2.10.0** from the CPU index instead of the release-candidate
  channel (`whl/test`) that `setup-env.sh` selects on release branches, so the
  measurement is reproducible against a fixed artifact. The candidate served on
  the tag date was later overwritten; the final wheel is the last candidate,
  with the same sha256, and is the version `torchvision 0.25.0` requires.
- **Dependency versions fixed at the tag date.** The tag pins no versions and
  the logs of its CI run are no longer available; Miniconda, the conda packages
  of the environment and every unpinned Python package are the newest releases
  at the tag commit (2026-01-06T11:14:43Z). `torchvision-extra-decoders` comes from
  PyPI (0.0.2) because the nightly builds of that date are no longer served.
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
