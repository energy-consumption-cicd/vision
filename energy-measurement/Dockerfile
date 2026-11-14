
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
ARG MINICONDA=Miniconda3-py310_24.4.0-0-Linux-x86_64.sh
ARG MINICONDA_SHA256=fdaa5afdea8c07b6f2203b8f95abe0e4e8c4d3fd3c10d19fe590311446591ffa
RUN curl -fsSL "https://repo.anaconda.com/miniconda/${MINICONDA}" -o /tmp/miniconda.sh && \
    echo "${MINICONDA_SHA256}  /tmp/miniconda.sh" | sha256sum -c - && \
    bash /tmp/miniconda.sh -b -p "${CONDA_DIR}" && \
    rm /tmp/miniconda.sh && \
    conda init bash

# setup-env.sh of the tag, each package at its newest pkgs/main build before the tag commit.
ARG PYTHON_VERSION=3.10.14
RUN conda create --name ci --quiet --yes \
        python="${PYTHON_VERSION}" pip=24.0 ninja=1.10.2 cmake=3.26.4 libpng=1.6.39 ffmpeg=4.2.2 && \
    conda run -n ci conda install --quiet --yes libjpeg-turbo -c pytorch

ENV TORCH_INDEX=https://download.pytorch.org/whl/cpu
ENV TORCH_VERSION=2.4.0

# The tag pins no versions: newest release of each package at the tag commit (2024-06-14T09:21:14Z).
RUN printf '%s\n' \
        'av==12.1.0' \
        'certifi==2024.6.2' \
        'charset-normalizer==3.3.2' \
        'coverage==7.5.3' \
        'exceptiongroup==1.2.1' \
        'expecttest==0.2.1' \
        'filelock==3.15.1' \
        'fsspec==2024.6.0' \
        'idna==3.7' \
        'iniconfig==2.0.0' \
        'jinja2==3.1.4' \
        'markupsafe==2.1.5' \
        'mpmath==1.3.0' \
        'networkx==3.3' \
        'numpy==1.26.4' \
        'packaging==24.1' \
        'pillow==10.3.0' \
        'pluggy==1.5.0' \
        'pytest==7.4.4' \
        'pytest-cov==5.0.0' \
        'pytest-mock==3.14.0' \
        'requests==2.32.3' \
        'setuptools==70.0.0' \
        'sympy==1.12.1' \
        'tomli==2.0.1' \
        'typing-extensions==4.12.2' \
        'urllib3==2.2.1' \
        > /constraints.txt

COPY . /project
WORKDIR /project

RUN conda run -n ci pip install --progress-bar=off -c /constraints.txt --upgrade setuptools && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt "av!=10.0.0" && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt "torch==${TORCH_VERSION}" \
        --index-url="${TORCH_INDEX}" && \
    conda run -n ci python setup.py egg_info && \
    conda run -n ci bash -c "sed -e '/^\$/,\$d' *.egg-info/requires.txt | tee requirements.txt" && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt -r requirements.txt && \
    conda run -n ci python setup.py develop && \
    conda run -n ci pip install --progress-bar=off -c /constraints.txt \
        "pytest<8" pytest-mock pytest-cov "expecttest!=0.2.0" requests

# setup.py develop builds in place; stale objects would let the measured build skip compilation.
RUN rm -rf /project/build && \
    find /project/torchvision -name '*.so' -exec touch -d @0 {} +

RUN mkdir -p /wheelhouse && \
    conda run -n ci pip download "torch==${TORCH_VERSION}" \
        --index-url="${TORCH_INDEX}" -c /constraints.txt -d /wheelhouse && \
    conda run -n ci pip download "av!=10.0.0" -c /constraints.txt -d /wheelhouse && \
    conda run -n ci pip download setuptools -c /constraints.txt -d /wheelhouse && \
    conda run -n ci pip download "pytest<8" pytest-mock pytest-cov "expecttest!=0.2.0" requests \
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
