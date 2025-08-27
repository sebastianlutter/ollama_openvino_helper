# Ollama + OpenVINO (ModelScope workflow)

This repository lets you:

1. build and run an Ollama server powered by OpenVINO (inside Docker),
2. fetch a **ModelScope** OpenVINO IR model, package it for Ollama,
3. import the packaged model into the running container and create it in Ollama.

see [ollama_openvino at openvinotoolkit/openvino_contrib](https://github.com/openvinotoolkit/openvino_contrib/tree/master/modules/ollama_openvino)

---

## Contents

```
.
├── Dockerfile                    # Builds an Ubuntu 24.04 image with OpenVINO GenAI + Ollama (OpenVINO backend)
├── docker.sh                     # Helper to build image / run container / inspect status
└── modelscope
    ├── get_model.sh              # Download ModelScope model, package as .tar.gz, generate Modelfile
    ├── ov_models/                # (created by get_model.sh) downloaded model directory
    └── use_model_in_docker.sh    # Copy tar + Modelfile into the running container and `ollama create`
```

The `Dockerfile` is adapted from
[openvino_contrib/modules/ollama_openvino/Dockerfile_genai_ubuntu24](https://raw.githubusercontent.com/openvinotoolkit/openvino_contrib/refs/heads/master/modules/ollama_openvino/Dockerfile_genai_ubuntu24) and builds a single binary `ollama` that serves with the OpenVINO backend.

---

## Prerequisites

* Docker Engine / Docker Desktop running on your machine
* Internet access (to fetch OpenVINO GenAI package, sources, and ModelScope models)
* Intel GPU / NPU drivers installed on the host system

---

## Quick start (recommended path)

From the repository root:

```bash
# 1) Build the image
./docker.sh build

# 2) Run the server container (exposes localhost:11434)
./docker.sh run
```

Open a **second terminal**:

```bash
cd modelscope/

# 3) Download and package the model from ModelScope
./get_model.sh zhaohb/Qwen3-8B-int4-sym-ov-npu
# This creates:
#   modelscope/ov_models/Qwen3-8B-int4-sym-ov-npu/   (downloaded IR)
#   modelscope/Qwen3-8B-int4-sym-ov-npu.tar.gz       (packaged tarball)
#   modelscope/Modelfile                             (points to the tarball)

# 4) Import tar + Modelfile into the running container and create the model in Ollama
./use_model_in_docker.sh ./Qwen3-8B-int4-sym-ov-npu.tar.gz
```

After step 4 completes, the model is registered in the container’s Ollama server. You can now call it from the host:

```bash
curl http://localhost:11434/api/generate \
  -d '{"model":"qwen3-8b-int4-sym-ov-npu","prompt":"Hello, OpenVINO!"}'
```

(If you passed a custom alias in the scripts, use that model name instead.)

---

## How it works

### The Docker image

The provided `Dockerfile`:

* Installs Go and OpenVINO GenAI (nightly build pinned in the Dockerfile)
* Builds the OpenVINO-based Ollama server from `openvino_contrib/modules/ollama_openvino`
* Exposes `ollama serve` on `0.0.0.0:11434`

> Entry point:
>
> ```bash
> ENTRYPOINT ["/bin/bash", "-c", "source /home/ollama_ov_server/openvino_genai_ubuntu24_2025.2.0.0.dev20250513_x86_64/setupvars.sh && /usr/bin/ollama serve"]
> ```

### `docker.sh`

A small manager for image/container lifecycle:

* `./docker.sh status` – prints Docker info, configured image reference, whether the image exists, and containers using it.
* `./docker.sh build` – builds the image from `Dockerfile`.

  * Options: `--force` to rebuild even if present, `--no-cache` to disable cache.
* `./docker.sh run` – runs the container with:

  * port mapping `-p 11434:11434`
  * a persistent Docker **volume** mounted at `/root/.ollama` (default name: `ollama-models`)

Environment overrides:

* `IMAGE_NAME` (default: `ollama_openvino_ubuntu24`)
* `IMAGE_TAG` (default: `v1`)
* `DOCKERFILE` (default: `Dockerfile`)
* `CONTEXT_DIR` (default: `.`)

Example:

```bash
IMAGE_TAG=v2 DOCKERFILE=./Dockerfile ./docker.sh build --no-cache
./docker.sh run                    # starts the v2 image
```

To use a custom volume name for persistence, pass it as the **second** argument to `run`:

```bash
./docker.sh run my-ollama-cache
```

### `modelscope/get_model.sh`

Downloads a ModelScope model and prepares it for Ollama:

* Creates/uses a local Python **venv** (default: `.venv` inside `modelscope/`) and installs `modelscope` if needed
* Downloads the model IR into `modelscope/ov_models/<model-id-sanitized>/`
* Packages that directory into `modelscope/<model-name>.tar.gz`
* Generates a `modelscope/Modelfile` that references the tarball and sets:

  * `ModelType "OpenVINO"`
  * `InferDevice "AUTO:NPU,CPU"` (default; configurable)
  * sensible text-generation parameters (configurable)

Usage:

```bash
cd modelscope/
./get_model.sh <modelscope_model_id> [--alias NAME] [--device DEVICE] [--ctx N] \
               [--venv PATH] [--out-dir DIR] [--force]
```

Examples:

```bash
# Default alias derived from model ID, device AUTO>NPU>CPU
./get_model.sh zhaohb/Qwen3-8B-int4-sym-ov-npu

# Explicit alias and strict NPU
./get_model.sh zhaohb/Qwen3-8B-int4-sym-ov-npu --alias qwen3-8b-ov-npu --device NPU

# Re-download and overwrite existing tar/Modelfile
./get_model.sh zhaohb/Qwen3-8B-int4-sym-ov-npu --force
```

Outputs (by default):

* `modelscope/ov_models/Qwen3-8B-int4-sym-ov-npu/`
* `modelscope/Qwen3-8B-int4-sym-ov-npu.tar.gz`
* `modelscope/Modelfile`

### `modelscope/use_model_in_docker.sh`

Copies the **tarball** and **Modelfile** into the running Ollama container and executes `ollama create` inside it.

Usage:

```bash
cd modelscope/
./use_model_in_docker.sh /path/to/model.tar.gz \
  [--container NAME_OR_ID] [--alias NAME] [--dest DIR] [--run]
```

* If `--container` is not specified, the script tries to auto-detect an Ollama container (looks for port 11434 or “ollama” in the name/image).
* If `--alias` is not specified, it is derived from the tar filename.
* `--dest` controls where files are placed in the container (default: `/root/modelpack/<alias>`).
* `--run` performs a short interactive prompt after creation to validate the model.

Examples:

```bash
# From inside modelscope/
./use_model_in_docker.sh ./Qwen3-8B-int4-sym-ov-npu.tar.gz --run

# From repository root (note the path)
./modelscope/use_model_in_docker.sh ./modelscope/Qwen3-8B-int4-sym-ov-npu.tar.gz \
  --container kind_kalam \
  --alias qwen3-8b-ov-npu
```

---

## Device selection (CPU / GPU / NPU)

By default, `get_model.sh` writes:

```text
ModelType "OpenVINO"
InferDevice "AUTO:NPU,CPU"
```

You can change this either by passing `--device` to `get_model.sh`:

```bash
./get_model.sh zhaohb/Qwen3-8B-int4-sym-ov-npu --device NPU
# or: --device "AUTO:GPU,CPU"
```

…or by editing the generated `Modelfile` before you import the model.

---

## Verifying the setup

With the container running:

```bash
# list models known to the container's Ollama
curl http://localhost:11434/api/tags

# quick generation call
curl http://localhost:11434/api/generate \
  -d '{"model":"qwen3-8b-int4-sym-ov-npu","prompt":"Write one short sentence."}'
```

---

## License

This repository contains helper scripts and a Dockerfile derived from OpenVINO Contrib examples. Check the upstream project’s license for their components, and apply a license of your choice for your own additions.

The helper scripts itself have MIT license
