
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
ARG MINICONDA=Miniconda3-py313_25.11.1-1-Linux-x86_64.sh
ARG MINICONDA_SHA256=e0b10e050e8928e2eb9aad2c522ee3b5d31d30048b8a9997663a8a460d538cef
RUN curl -fsSL "https://repo.anaconda.com/miniconda/${MINICONDA}" -o /tmp/miniconda.sh && \
    echo "${MINICONDA_SHA256}  /tmp/miniconda.sh" | sha256sum -c - && \
    bash /tmp/miniconda.sh -b -p "${CONDA_DIR}" && \
    rm /tmp/miniconda.sh && \
    conda init bash

RUN conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main && \
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r

# setup-env.sh of the tag, each package at its newest pkgs/main build before the tag commit.
ARG PYTHON_VERSION=3.10.19
RUN conda create --name ci --quiet --yes \
        python="${PYTHON_VERSION}" pip=25.3 ninja=1.13.1 cmake=4.1.2 libpng=1.6.50 libwebp=1.6.0 && \
    conda run -n ci conda install --quiet --yes libjpeg-turbo -c pytorch

ENV TORCH_INDEX=https://download.pytorch.org/whl/cpu
ENV TORCH_VERSION=2.10.0
ENV EXTRA_DECODERS_VERSION=0.0.2

# The tag pins no versions: newest release of each package at the tag commit (2026-01-06T11:14:43Z).
RUN printf '%s\n' \
        'av==16.0.1' \
        'certifi==2026.1.4' \
        'charset-normalizer==3.4.4' \
        'coverage==7.13.1' \
        'exceptiongroup==1.3.1' \
        'expecttest==0.3.0' \
        'filelock==3.20.2' \
        'fsspec==2025.12.0' \
        'idna==3.11' \
        'iniconfig==2.3.0' \
        'jinja2==3.1.6' \
        'markupsafe==3.0.3' \
        'mpmath==1.3.0' \
        'networkx==3.4.2' \
        'numpy==2.2.6' \
        'packaging==25.0' \
        'pillow==12.1.0' \
        'pluggy==1.6.0' \
        'pytest==7.4.4' \
        'pytest-cov==7.0.0' \
        'pytest-mock==3.15.1' \
        'requests==2.32.5' \
        'sympy==1.14.0' \
        'tomli==2.3.0' \
        'typing-extensions==4.15.0' \
        'urllib3==2.6.2' \
        > /constraints.txt

COPY . /project
WORKDIR /project

RUN conda run -n ci pip install --progress-bar=off --upgrade setuptools==72.1.0 && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt "av!=10.0.0" && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt "torch==${TORCH_VERSION}" \
        --index-url="${TORCH_INDEX}" && \
    conda run -n ci pip install -e . -v --no-build-isolation -c /constraints.txt && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt \
        "torchvision-extra-decoders==${EXTRA_DECODERS_VERSION}" && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt \
        "pytest<8" pytest-mock pytest-cov "expecttest!=0.2.0" requests

RUN mkdir -p /wheelhouse && \
    conda run -n ci pip download "torch==${TORCH_VERSION}" \
        --index-url="${TORCH_INDEX}" -c /constraints.txt -d /wheelhouse && \
    conda run -n ci pip download "av!=10.0.0" -c /constraints.txt -d /wheelhouse && \
    conda run -n ci pip download \
        "torchvision-extra-decoders==${EXTRA_DECODERS_VERSION}" -d /wheelhouse && \
    conda run -n ci pip download setuptools==72.1.0 -d /wheelhouse && \
    conda run -n ci pip download "pytest<8" pytest-mock pytest-cov \
        "expecttest!=0.2.0" requests -c /constraints.txt -d /wheelhouse

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
