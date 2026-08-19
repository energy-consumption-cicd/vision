#!/usr/bin/env bash

set -euo pipefail
STAGE="${1:?stage required}"

cd /project

eval "$(conda shell.bash hook)"
conda activate ci

case "$STAGE" in

  build)
    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        setuptools==72.1.0

    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        "torch==2.13.0"

    pip install -e . -v --no-build-isolation --no-index --find-links=/wheelhouse

    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        torchvision-extra-decoders

    conda list
    python -m torch.utils.collect_env

    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        "pytest<8" pytest-mock pytest-cov "expecttest!=0.2.0" requests
    ;;

  test)
    python test/smoke_test.py

    BLOCK_EXIT=0
    correr_bloco() {
        local nome="$1"; shift
        echo "=== BLOCK ${nome} - start: $(date -u +%FT%TZ) ==="
        set +e
        "$@"
        local rc=$?
        set -e
        echo "=== BLOCK ${nome} - end: $(date -u +%FT%TZ) exit=${rc} ==="
        if [ "$rc" -ne 0 ] && [ "$BLOCK_EXIT" -eq 0 ]; then
            BLOCK_EXIT="$rc"
        fi
        return 0
    }

    correr_bloco A/3 pytest test/test_models.py -k "test_classification_model" \
        --junit-xml=/project/test-results-A.xml \
        -v --durations=25

    correr_bloco B/3 pytest test/test_models.py -k "not test_classification_model" \
        --junit-xml=/project/test-results-B.xml \
        -v --durations=25

    correr_bloco C/3 pytest --ignore-glob="*test_video*" --ignore-glob="*test_onnx*" \
        --ignore=test/test_models.py \
        --junit-xml=/project/test-results-C.xml \
        -v --durations=25 -k "not TestFxFeatureExtraction"

    echo "=== stage test: aggregated exit = ${BLOCK_EXIT} ==="
    exit "$BLOCK_EXIT"
    ;;

  *)
    echo "Stage desconhecido: $STAGE" >&2
    exit 1
    ;;
esac
