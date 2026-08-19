# Energy measurement instrumentation

## Purpose

This directory is not part of the upstream torchvision repository. It was added
to measure the energy consumption of CI/CD pipeline commands on controlled
hardware, using Intel RAPL counters. The measured construct is the energy of
the CI commands on a controlled bench, not the energy of GitHub-hosted CI in
production.

## Non-invasiveness

No original project file is created or modified. The only additions are this
directory and `.github/workflows/energy-measurement.yml`. Verify with:

```bash
git remote add upstream https://github.com/pytorch/vision.git
git fetch upstream
git diff --name-only upstream/main...HEAD
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
isolates container overhead and, in this project, was used to locate an I/O
stall inside the container rather than in teardown.

Per-stage CPU time is captured inside the container: file descriptor 3
preserves the workload's stderr while `time` writes to `/timing`, so the CPU
time of child processes is attributed to the stage.

Host paging is recorded per stage (`swap_in_pages`, `swap_out_pages`) from
`/proc/vmstat`.

## How to run

```bash
docker build -t torchvision-medicao -f energy-measurement/Dockerfile .
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
| `build` | the conda environment setup and package install of `unittest.sh`/`setup-env.sh` | offline install of `setuptools`, `torch`, the project itself (editable), the extra decoders and the test utilities |
| `test` | `python test/smoke_test.py` followed by the `pytest` invocation of `unittest.sh` | smoke test, then the suite split into three static blocks (see below) |

Reference cell: `tests.yml`, job `unittests-linux`, CPU / Python 3.10 — cell 1
of 6.

## Deviations from the upstream pipeline

- **Test suite partitioned into three static blocks.** The upstream job runs one
  `pytest` invocation; here it is split into `test_models.py -k
  test_classification_model`, `test_models.py -k "not
  test_classification_model"`, and the remainder. The split is imposed by the
  bench's memory limit, is **static and deterministic** (file path and function
  name, no dynamic sharding), and coverage was proved by `--collect-only` to
  equal the original suite. The stage exit code is the aggregate of the three.
- **Offline dependencies and pre-baked weights.** Everything is built into the
  image and installed with `--no-index`. RAPL has no network domain.
- **Local HTTPS stub** for `sourceforge.net` and `drive.google.com`, mapped to
  loopback with `--add-host`, because a small number of tests dereference those
  hosts. The stub serves the same bytes, verified by sha256 against a manifest.
- **`GITHUB_ACTIONS=true`.** The upstream job runs on GitHub Actions and the
  suite branches on this variable; setting it is a fidelity correction, not an
  addition.
- **Stable torch 2.13.0** instead of the upstream nightly, so the measurement is
  reproducible against a fixed artifact.
- **Memory limit of 14 GiB** with `--memory-swap` equal to it, so
  `memory.swap.max` is zero and the container cannot page. The value came from a
  four-execution gate, not an estimate.

## Output schema

One CSV per run, one row per stage plus a `total` row:

```
run, stage, energy_pkg_j, energy_cores_j, energy_gpu_j, energy_ram_j,
wall_time_s, user_time_s, sys_time_s, energy_ram_liquid_raw_j,
wall_time_container_s, swap_in_pages, swap_out_pages
```

The first nine columns are the official schema shared by every project in the
study; the last four are diagnostic. Exit codes are written to a sidecar
`exit_codes_run_NN.txt`, and the actual execution order to
`ordem_execucao.txt`.

## Reproducibility notes

Bench: Intel Core i7-9700 (8 cores, no SMT), 16 GB RAM, Crucial BX500 SATA SSD,
Ubuntu 24.04 LTS, kernel 6.8.0, Docker 29.x.

Container flags: `--rm --privileged --network none --memory=14g
--memory-swap=14g`, plus the two `--add-host` entries for the HTTPS stub.

The upstream runner has 48 vCPUs against 8 on this bench; thread counts are
inherited from the upstream commands and are not overridden.
