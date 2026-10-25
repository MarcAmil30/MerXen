# Match the CUDA minor used by the pinned torch runtime on Dwight.
FROM nvidia/cuda:13.0.2-cudnn-devel-rockylinux9 AS compile-image

# install required command-line tools
RUN dnf install -y procps-ng

# install python 3.12 and git
RUN dnf install -y python3.12 && dnf clean all
RUN dnf install -y python3.12-pip && dnf clean all
RUN dnf install -y git && dnf clean all
RUN ln -s /usr/bin/python3.12 /usr/local/bin/python3
RUN ln -s /usr/bin/python3.12 /usr/local/bin/python
RUN python3 --version

# Proseg
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# The same ProSeg as params.proseg_version / proseg_git_rev: ENSURE_PROSEG
# rejects any other version and would then try to build one at run time.
ARG PROSEG_GIT_URL=https://github.com/dcjones/proseg.git
ARG PROSEG_GIT_REV=e7df1eace923ce4c6ec70b2c597c5d126aa3db88
RUN cargo install --git "${PROSEG_GIT_URL}" --rev "${PROSEG_GIT_REV}" proseg
RUN ln -sf /usr/local/cargo/bin/proseg /usr/local/bin/proseg

# Install the pinned dependency tree from the lockfile, then the checked-out
# MerXen source without re-resolving its dependencies, so the image matches
# CI. The generated lock includes the entire dependency tree. --no-deps avoids
# re-resolving cell_type_mapper's unpinned abc_atlas_access Git URL against the
# commit already pinned in the lock.
RUN python3 -m pip install --no-cache-dir "uv==0.11.7"
WORKDIR /opt/merxen
COPY requirements/requirements.lock ./requirements/requirements.lock
RUN uv pip install --system --python /usr/bin/python3.12 --no-cache --no-deps -r requirements/requirements.lock
COPY pyproject.toml README.md ./
COPY src ./src
RUN uv pip install --system --python /usr/bin/python3.12 --no-cache --no-deps .

# Cellpose-SAM weights (1.2 GB), fetched at build time: Cellpose 4 loads them
# whatever cellpose_model_type says, and would otherwise download them into
# ~/.cellpose on first use, which needs network and a writable home. Building
# the model the way MerXen does fetches the right file for the locked Cellpose
# (4.1.1: "cpsam"; 4.2 renamed it "cpsam_v2").
ENV CELLPOSE_LOCAL_MODELS_PATH=/opt/cellpose/models
RUN python3 -c "from cellpose import models; models.CellposeModel(gpu=False)" && \
    ls -l /opt/cellpose/models && chmod -R a+rX /opt/cellpose

# Fallback cache folders: a non-root container user usually has no writable
# home. MerXen's own code points both at the task folder where it can.
ENV MPLCONFIGDIR=/tmp/matplotlib \
    NUMBA_CACHE_DIR=/tmp/numba \
    XDG_CACHE_HOME=/tmp/.cache

CMD ["python3"]
