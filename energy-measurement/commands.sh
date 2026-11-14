#!/usr/bin/env bash

set -euo pipefail
STAGE="${1:?stage required}"

cd /project

eval "$(conda shell.bash hook)"
conda activate ci

case "$STAGE" in

  build)
    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        --upgrade setuptools

    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        "av!=10.0.0"

    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        "torch==2.2.0"

    python setup.py egg_info
    sed -e '/^$/,$d' *.egg-info/requires.txt | tee requirements.txt
    pip install --progress-bar=off --no-index --find-links=/wheelhouse -r requirements.txt

    python setup.py develop

    conda list
    python -m torch.utils.collect_env

    pip install --progress-bar=off --no-index --find-links=/wheelhouse \
        "pytest<8" pytest-mock pytest-cov expecttest
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

    correr_bloco A/4 pytest test/test_models.py -k "test_classification_model" \
        --junit-xml=/project/test-results-A.xml \
        -v --durations=25

    correr_bloco B/4 pytest test/test_models.py -k "not test_classification_model" \
        --junit-xml=/project/test-results-B.xml \
        -v --durations=25

    correr_bloco C/4 pytest --ignore=test/test_models.py \
        -k "not TestFxFeatureExtraction" \
        --junit-xml=/project/test-results-C.xml \
        -v --durations=25

    # Same tests as upstream, in a process of their own: within block C the class exceeds the 14g container limit.
    correr_bloco D/4 pytest test/test_backbone_utils.py -k "TestFxFeatureExtraction" \
        --junit-xml=/project/test-results-D.xml \
        -v --durations=25

    echo "=== stage test: aggregated exit = ${BLOCK_EXIT} ==="
    exit "$BLOCK_EXIT"
    ;;

  *)
    echo "Unknown stage: $STAGE" >&2
    exit 1
    ;;
esac
