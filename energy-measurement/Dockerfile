# av 11.0.0, the release current at the tag commit, is published as source only. Its wheel is rebuilt as
# upstream built it: manylinux2014, the FFmpeg 6.0 build of pyav-ffmpeg 6.0.0-1, auditwheel repair.
FROM quay.io/pypa/manylinux2014_x86_64@sha256:93fa501a7ae8cee9fbc15f3070b9b718e84f9bbf9645b1134d365f7a501ce98a AS av
ARG PYAV_FFMPEG_SHA256=9a225c39f4cde492d951079b193c36ccc61be2341d7f1d04a98c3061c0186067
ARG AV_SDIST_SHA256=48223f000a252070f8e700ff634bb7fb3aa1b7bc7e450373029fbdd6f369ac31
# CentOS 7 is past end of life: its packages are served from the vault.
RUN sed -i -e 's|^mirrorlist=|#mirrorlist=|' -e 's|^# *baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|' \
        /etc/yum.repos.d/*.repo && \
    yum install -y alsa-lib libxcb && \
    curl -fsSL -o /tmp/ffmpeg.tar.gz \
        https://github.com/PyAV-Org/pyav-ffmpeg/releases/download/6.0.0-1/ffmpeg-manylinux_x86_64.tar.gz && \
    echo "${PYAV_FFMPEG_SHA256}  /tmp/ffmpeg.tar.gz" | sha256sum -c - && \
    mkdir -p /tmp/vendor && tar -C /tmp/vendor -xf /tmp/ffmpeg.tar.gz
RUN printf '%s\n' 'cython==3.0.8' 'setuptools==69.0.3' 'wheel==0.42.0' > /constraints-av-build.txt && \
    printf 'av==11.0.0 --hash=sha256:%s\n' "${AV_SDIST_SHA256}" > /av.txt && \
    export LD_LIBRARY_PATH=/tmp/vendor/lib PKG_CONFIG_PATH=/tmp/vendor/lib/pkgconfig \
           PIP_CONSTRAINT=/constraints-av-build.txt && \
    /opt/python/cp310-cp310/bin/pip wheel --progress-bar=off --no-deps --no-binary av --require-hashes \
        -r /av.txt -w /tmp/dist && \
    auditwheel repair -w /wheelhouse /tmp/dist/av-11.0.0-*.whl

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
        build-essential \
        curl \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV CONDA_DIR=/opt/conda
ENV PATH="${CONDA_DIR}/bin:${PATH}"
# Installer current at the tag commit, in place of the moving Miniconda3-latest.
ARG MINICONDA=Miniconda3-py310_23.11.0-2-Linux-x86_64.sh
ARG MINICONDA_SHA256=35a58b8961e1187e7311b979968662c6223e86e1451191bed2e67a72b6bd0658
RUN curl -fsSL "https://repo.anaconda.com/miniconda/${MINICONDA}" -o /tmp/miniconda.sh && \
    echo "${MINICONDA_SHA256}  /tmp/miniconda.sh" | sha256sum -c - && \
    bash /tmp/miniconda.sh -b -p "${CONDA_DIR}" && \
    rm /tmp/miniconda.sh && \
    conda init bash

# setup-env.sh of the tag, each package at its newest pkgs/main build before the tag commit.
ARG PYTHON_VERSION=3.10.13
RUN conda create --name ci --quiet --yes \
        python="${PYTHON_VERSION}" pip=23.3.1 ninja=1.10.2 cmake=3.26.4 libpng=1.6.39 ffmpeg=4.2.2 && \
    conda run -n ci conda install --quiet --yes libjpeg-turbo -c pytorch

# markupsafe of the tag date is not mirrored on whl/cpu, so PyPI backs the torch install.
ENV TORCH_INDEX=https://download.pytorch.org/whl/cpu
ENV TORCH_VERSION=2.2.0

# The tag pins no versions: newest release of each package at the tag commit (2024-01-29T14:10:29Z).
RUN printf '%s\n' \
        'av==11.0.0' \
        'certifi==2023.11.17' \
        'charset-normalizer==3.3.2' \
        'coverage==7.4.1' \
        'exceptiongroup==1.2.0' \
        'expecttest==0.2.1' \
        'filelock==3.13.1' \
        'fsspec==2023.12.2' \
        'idna==3.6' \
        'iniconfig==2.0.0' \
        'jinja2==3.1.3' \
        'markupsafe==2.1.4' \
        'mpmath==1.3.0' \
        'networkx==3.2.1' \
        'numpy==1.26.3' \
        'packaging==23.2' \
        'pillow==10.2.0' \
        'pluggy==1.4.0' \
        'pytest==7.4.4' \
        'pytest-cov==4.1.0' \
        'pytest-mock==3.12.0' \
        'requests==2.31.0' \
        'setuptools==69.0.3' \
        'sympy==1.12' \
        'tomli==2.0.1' \
        'typing-extensions==4.9.0' \
        'urllib3==2.1.0' \
        > /constraints.txt

COPY --from=av /wheelhouse/ /wheelhouse/

COPY . /project
WORKDIR /project

RUN conda run -n ci pip install --progress-bar=off -c /constraints.txt --upgrade setuptools && \
    conda run -n ci pip install --progress-bar=off --no-index --find-links=/wheelhouse -c /constraints.txt "av!=10.0.0" && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt "torch==${TORCH_VERSION}" \
        --index-url="${TORCH_INDEX}" --extra-index-url=https://pypi.org/simple && \
    conda run -n ci python setup.py egg_info && \
    conda run -n ci bash -c "sed -e '/^\$/,\$d' *.egg-info/requires.txt | tee requirements.txt" && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt -r requirements.txt && \
    conda run -n ci python setup.py develop && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt \
        "pytest<8" pytest-mock pytest-cov expecttest

# setup.py develop builds in place; stale objects would let the measured build skip compilation.
RUN rm -rf /project/build && \
    find /project/torchvision -name '*.so' -exec touch -d @0 {} +

RUN mkdir -p /wheelhouse && \
    conda run -n ci pip download "torch==${TORCH_VERSION}" \
        --index-url="${TORCH_INDEX}" --extra-index-url=https://pypi.org/simple -c /constraints.txt -d /wheelhouse && \
    conda run -n ci pip download setuptools -c /constraints.txt -d /wheelhouse && \
    conda run -n ci pip download "pytest<8" pytest-mock pytest-cov expecttest \
        -c /constraints.txt -d /wheelhouse

RUN conda run -n ci python -c "\
from torchvision.models import resnet50, ResNet50_Weights; \
resnet50(weights=ResNet50_Weights.DEFAULT)"

ENV GITHUB_ACTIONS=true

RUN conda run -n ci python -c "\
from torchvision.models.segmentation import lraspp_mobilenet_v3_large; \
from torchvision.models import MobileNet_V3_Large_Weights as W; \
lraspp_mobilenet_v3_large(weights=None, weights_backbone=W.IMAGENET1K_V1)"

COPY --from=prebake serve_stub.py   /opt/prebake/serve_stub.py
COPY --from=prebake entrypoint.sh   /usr/local/bin/medicao-entrypoint.sh
COPY --from=prebake gifs/           /opt/prebake/gifs/
COPY --from=prebake SHA256SUMS      /opt/prebake/SHA256SUMS

RUN set -eu; \
    mkdir -p /opt/prebake/tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -days 36500 -nodes \
        -keyout /opt/prebake/tls/ca.key -out /opt/prebake/tls/ca.crt \
        -subj "/CN=medicao prebake CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout /opt/prebake/tls/server.key -out /tmp/server.csr \
        -subj "/CN=sourceforge.net" 2>/dev/null; \
    printf 'subjectAltName=DNS:sourceforge.net,DNS:drive.google.com\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' \
        > /tmp/server.ext; \
    openssl x509 -req -in /tmp/server.csr -sha256 -days 36500 \
        -CA /opt/prebake/tls/ca.crt -CAkey /opt/prebake/tls/ca.key \
        -CAcreateserial -extfile /tmp/server.ext \
        -out /opt/prebake/tls/server.crt 2>/dev/null; \
    cp /opt/prebake/tls/ca.crt /usr/local/share/ca-certificates/medicao-prebake.crt; \
    update-ca-certificates >/dev/null; \
    CERTIFI=$(conda run -n ci python -c "import certifi;print(certifi.where())" | tr -d '\r\n'); \
    cat /opt/prebake/tls/ca.crt >> "$CERTIFI"; \
    echo "CA appended to certifi at $CERTIFI"; \
    OPENSSL_CA=$(conda run -n ci python -c "import ssl;print(ssl.get_default_verify_paths().openssl_cafile)" | tr -d '\r\n'); \
    cat /opt/prebake/tls/ca.crt >> "$OPENSSL_CA"; \
    echo "CA appended to the conda OpenSSL bundle at $OPENSSL_CA"; \
    chmod 0644 /opt/prebake/tls/server.key /opt/prebake/tls/server.crt; \
    chmod 0755 /usr/local/bin/medicao-entrypoint.sh; \
    rm -f /tmp/server.csr /tmp/server.ext /opt/prebake/tls/ca.key /opt/prebake/tls/ca.srl

ENTRYPOINT ["/usr/local/bin/medicao-entrypoint.sh"]

RUN set -eu; \
    W=/root/.cache/torch/hub/checkpoints/resnet50-11ad3fa6.pth; \
    test -f "$W" || { echo "FAIL GATE 1: $W missing" >&2; exit 1; }; \
    SZ=$(stat -c%s "$W"); \
    [ "$SZ" -gt 94000000 ] || { echo "FAIL GATE 1: $W has $SZ bytes (expected about 97.8 MB)" >&2; exit 1; }; \
    echo "GATE 1: resnet50 weights present ($SZ bytes)"

RUN set -eu; \
    conda run -n ci python -c "\
import torch, torchvision; \
assert torch.ops.torchvision.nms is not None; \
assert torch.ops.image.decode_png is not None; \
print('GATE 2: torchvision', torchvision.__version__, '- C++ extension loaded, ops registered')"

RUN set -eu; \
    cd /opt/prebake && sha256sum -c SHA256SUMS >/dev/null \
      || { echo "FAIL GATE 3a: GIF sha256 does not match the manifest" >&2; exit 1; }; \
    echo "GATE 3a: 7 GIFs intact (sha256 verified)"; \
    W=/root/.cache/torch/hub/checkpoints/mobilenet_v3_large-8738ca79.pth; \
    test -f "$W" && [ "$(stat -c%s "$W")" -gt 18000000 ] \
      || { echo "FAIL GATE 3b: lraspp IMAGENET1K_V1 backbone missing or truncated" >&2; exit 1; }; \
    echo "GATE 3b: lraspp backbone present ($(stat -c%s "$W") bytes)"; \
    /opt/conda/envs/ci/bin/python /opt/prebake/serve_stub.py & \
    sleep 3; \
    conda run -n ci python -c "\
import socket, requests, urllib.request, ssl; \
_orig = socket.getaddrinfo; \
socket.getaddrinfo = lambda h,p,*a,**k: _orig('127.0.0.1',p,*a,**k); \
r = requests.get('https://sourceforge.net/p/giflib/code/ci/master/tree/pic/fire.gif?format=raw', timeout=10); \
assert r.status_code == 200 and r.content[:6] in (b'GIF87a', b'GIF89a'), 'requests/certifi failed'; \
print('requests via certifi: OK,', len(r.content), 'bytes'); \
u = urllib.request.urlopen('https://drive.google.com/file/d/XYZ/view', timeout=10); \
assert u.status == 200 and u.url.endswith('/view'), 'urllib/system failed or redirected'; \
print('urllib via system truststore: OK, no redirect')" \
      || { echo "FAIL GATE 3c: network stub not responding on both truststores" >&2; exit 1; }; \
    echo "GATE 3c: stub answers requests (certifi) and urllib (system)"

RUN conda run -n ci pip freeze > /pip-freeze-imagem.txt && \
    conda run -n ci python -c "import torch; print('torch', torch.__version__)" \
      >> /pip-freeze-imagem.txt && \
    echo "Pins recorded at /pip-freeze-imagem.txt"
